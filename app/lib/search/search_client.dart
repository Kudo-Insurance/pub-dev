// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:gcloud/service_scope.dart' as ss;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../scorecard/backend.dart';
import '../shared/configuration.dart';
import '../shared/redis_cache.dart' show cache;
import '../shared/utils.dart';

import 'search_service.dart';

final _logger = Logger('pub.search.client');

/// Sets the search client.
void registerSearchClient(SearchClient client) =>
    ss.register(#_searchClient, client);

/// The active search client.
SearchClient get searchClient => ss.lookup(#_searchClient) as SearchClient;

/// Client methods that access the search service and the internals of the
/// indexed data.
class SearchClient {
  /// The HTTP client used for making calls to our search service.
  final http.Client _httpClient;

  SearchClient([http.Client client]) : _httpClient = client ?? http.Client();

  /// Calls the search service (or uses cache) to serve the [query].
  ///
  /// If the [updateCacheAfter] is set, and the currently cached value is older
  /// than the specified value, the client will do a non-cached request to the
  /// search service and update the cached value.
  Future<PackageSearchResult> search(
    ServiceSearchQuery query, {
    Duration ttl,
    Duration updateCacheAfter,
  }) async {
    // check validity first
    final validity = query.evaluateValidity();
    if (validity.isRejected) {
      return PackageSearchResult.empty(
        message: 'Search query rejected. ${validity.rejectReason}',
      );
    }

    final String httpHostPort = activeConfiguration.searchServicePrefix;
    final serviceUrlParams = Uri(queryParameters: query.toUriQueryParameters());
    final String serviceUrl = '$httpHostPort/search$serviceUrlParams';

    Future<PackageSearchResult> searchFn() async {
      final response = await getUrlWithRetry(
        _httpClient,
        serviceUrl,
        timeout: Duration(seconds: 5),
        // limit to a single attempt, no need to retry after timeout
        retryCount: 0,
      );
      if (response.statusCode == searchIndexNotReadyCode) {
        // Search request before the service initialization completed.
        // TODO: retry request, maybe another search instance will be able to serve it
        return null;
      }
      if (response.statusCode != 200) {
        // There has been an issue with the service
        // TODO: retry request, maybe another search instance will be able to serve it
        throw Exception('Service returned status code ${response.statusCode}');
      }
      final result = PackageSearchResult.fromJson(
        json.decode(response.body) as Map<String, dynamic>,
      );
      if (!result.isLegit) {
        // Search request before the service initialization completed.
        // TODO: retry request, maybe another search instance will be able to serve it
        return null;
      }
      return result;
    }

    final cacheEntry = cache.packageSearchResult(serviceUrl, ttl: ttl);
    var result = await cacheEntry.get(searchFn);

    if (updateCacheAfter != null &&
        result?.timestamp != null &&
        result.age > updateCacheAfter) {
      _logger.info('Updating stale cache entry.');
      final value = await searchFn();
      if (value != null) {
        await cacheEntry.set(value);
        result = value;
      }
    }

    return result ??
        PackageSearchResult.empty(
            message: 'Search is temporarily unavailable.');
  }

  /// Search service maintains a separate index in each of the running instances.
  /// This method will update the [ScoreCard] entry of the package, and it will
  /// be picked up by each search index individually, within a few minutes.
  Future<void> triggerReindex(String package, String version) async {
    await scoreCardBackend.updateScoreCard(package, version);
  }

  Future<void> close() async {
    _httpClient.close();
  }
}
