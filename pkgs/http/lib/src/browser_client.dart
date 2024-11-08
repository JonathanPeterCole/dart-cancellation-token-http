// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:js_interop';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:web/web.dart' show XHRGetters, XMLHttpRequest;

import 'base_client.dart';
import 'base_request.dart';
import 'byte_stream.dart';
import 'exception.dart';
import 'streamed_response.dart';

final _digitRegex = RegExp(r'^\d+$');

/// Create a [BrowserClient].
///
/// Used from conditional imports, matches the definition in `client_stub.dart`.
BaseClient createClient() {
  if (const bool.fromEnvironment('no_default_http_client')) {
    throw StateError('no_default_http_client was defined but runWithClient '
        'was not used to configure a Client implementation.');
  }
  return BrowserClient();
}

/// A `package:web`-based HTTP client that runs in the browser and is backed by
/// [XMLHttpRequest].
///
/// This client inherits some of the limitations of XMLHttpRequest. It ignores
/// the [BaseRequest.contentLength], [BaseRequest.persistentConnection],
/// [BaseRequest.followRedirects], and [BaseRequest.maxRedirects] fields. It is
/// also unable to stream requests or responses; a request will only be sent and
/// a response will only be returned once all the data is available.
class BrowserClient extends BaseClient {
  /// The currently active XHRs.
  ///
  /// These are aborted if the client is closed.
  final _xhrs = <XMLHttpRequest>{};

  /// Whether to send credentials such as cookies or authorization headers for
  /// cross-site requests.
  ///
  /// Defaults to `false`.
  bool withCredentials = false;

  bool _isClosed = false;

  /// Sends an HTTP request and asynchronously returns the response.
  @override
  Future<StreamedResponse> send(
    BaseRequest request, {
    CancellationToken? cancellationToken,
  }) async {
    if (cancellationToken?.isCancelled ?? false) {
      throw cancellationToken!.exception!;
    } else if (_isClosed) {
      throw ClientException(
          'HTTP request failed. Client is already closed.', request.url);
    }

    XMLHttpRequest? xhr = XMLHttpRequest();
    final completer = CancellableCompleter<StreamedResponse>.sync(
      cancellationToken,
      onCancel: () {
        _xhrs.remove(xhr);
        xhr.abort();
      },
    );

    unawaited(request.finalize().toBytes().then((bytes) async {
      // Don't continue if the request has been cancelled at this point
      if (cancellationToken?.isCancelled ?? false) return;

      // Prepare the request
      _xhrs.add(xhr);
      xhr
        ..open(request.method, '${request.url}', true)
        ..responseType = 'arraybuffer'
        ..withCredentials = withCredentials;
      for (var header in request.headers.entries) {
        xhr.setRequestHeader(header.key, header.value);
      }

      // Prepare the response handler
      unawaited(xhr.onLoad.first.then((_) {
        if (xhr.responseHeaders['content-length'] case final contentLengthHeader
            when contentLengthHeader != null &&
                !_digitRegex.hasMatch(contentLengthHeader)) {
          completer.completeError(ClientException(
            'Invalid content-length header [$contentLengthHeader].',
            request.url,
          ));
          return;
        }
        var body = (xhr.response as JSArrayBuffer).toDart.asUint8List();
        var responseUrl = xhr.responseURL;
        var url = responseUrl.isNotEmpty ? Uri.parse(responseUrl) : request.url;
        completer.complete(StreamedResponseV2(
          ByteStream.fromBytes(body),
          xhr.status,
          contentLength: body.length,
          request: request,
          url: url,
          headers: xhr.responseHeaders,
          reasonPhrase: xhr.statusText,
        ));
        _xhrs.remove(xhr);
      }));

      // Prepare the error handler
      unawaited(xhr.onError.first.then((_) {
        // Unfortunately, the underlying XMLHttpRequest API doesn't expose any
        // specific information about the error itself.
        completer.completeError(
          ClientException('XMLHttpRequest error.', request.url),
          StackTrace.current,
        );
        _xhrs.remove(xhr);
      }));

      // Send the request
      xhr.send(bytes.toJS);
    }));

    return completer.future;
  }

  /// Closes the client.
  ///
  /// This terminates all active requests.
  @override
  void close() {
    _isClosed = true;
    for (var xhr in _xhrs) {
      xhr.abort();
    }
    _xhrs.clear();
  }
}

extension on XMLHttpRequest {
  Map<String, String> get responseHeaders {
    // from Closure's goog.net.Xhrio.getResponseHeaders.
    var headers = <String, String>{};
    var headersString = getAllResponseHeaders();
    var headersList = headersString.split('\r\n');
    for (var header in headersList) {
      if (header.isEmpty) {
        continue;
      }

      var splitIdx = header.indexOf(': ');
      if (splitIdx == -1) {
        continue;
      }
      var key = header.substring(0, splitIdx).toLowerCase();
      var value = header.substring(splitIdx + 2);
      if (headers.containsKey(key)) {
        headers[key] = '${headers[key]}, $value';
      } else {
        headers[key] = value;
      }
    }
    return headers;
  }
}
