import Foundation

/// JavaScript injected into every WKWebView at document start.
/// Hooks console output, uncaught exceptions and resource timing, and forwards
/// everything to the native `naviDevTools` script message handler, which feeds
/// DevToolsStore. Without this bridge the DevTools panels stay empty forever.
enum DevToolsJavaScript {

    static let source = """
    (function() {
      if (window.__naviDevToolsInstalled) return;
      window.__naviDevToolsInstalled = true;

      function bridge() {
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.naviDevTools) {
            return window.webkit.messageHandlers.naviDevTools;
          }
        } catch (e) {}
        return null;
      }

      function post(payload) {
        var b = bridge();
        if (b) { try { b.postMessage(payload); } catch (e) {} }
      }

      function ser(v) {
        try {
          if (v === undefined) return 'undefined';
          if (v === null) return 'null';
          if (typeof v === 'string') return v;
          if (v instanceof Error) return (v.stack || (v.name + ': ' + v.message));
          var seen = arguments.length > 1 ? arguments[1] : 0;
          if (typeof v === 'object' && seen < 3) {
            return JSON.stringify(v, function(k, val) {
              return (typeof val === 'object' && val !== null && seen >= 2) ? '[Object]' : val;
            });
          }
          return String(v);
        } catch (e) { return '[unserializable]'; }
      }

      ['log', 'info', 'warn', 'error', 'debug'].forEach(function(level) {
        var original = console[level] ? console[level].bind(console) : function() {};
        console[level] = function() {
          var args = Array.prototype.slice.call(arguments);
          var text = args.map(function(a) { return ser(a); }).join(' ');
          post({ kind: 'console', level: level, message: text });
          original.apply(console, args);
        };
      });

      window.addEventListener('error', function(e) {
        var msg = (e.message || 'Script error');
        if (e.filename) msg += ' @ ' + e.filename + ':' + (e.lineno || 0);
        post({ kind: 'exception', message: msg });
      }, true);

      window.addEventListener('unhandledrejection', function(e) {
        var reason = e.reason ? ser(e.reason) : 'Unhandled promise rejection';
        post({ kind: 'exception', message: reason });
      }, true);

      if (window.PerformanceObserver) {
        try {
          var obs = new PerformanceObserver(function(list) {
            list.getEntries().forEach(function(entry) {
              if (entry.entryType !== 'resource') return;
              post({
                kind: 'resource',
                method: 'GET',
                url: entry.name,
                duration: Math.max(1, Math.round(entry.duration || 0)),
                size: entry.transferSize || 0
              });
            });
          });
          obs.observe({ entryTypes: ['resource'] });
        } catch (e) {}
      }
    })();
    """
}

/// Receives messages posted from DevToolsJavaScript and forwards them to
/// DevToolsStore. Kept as a small standalone class because
/// WKUserContentController retains its handlers strongly — attaching the
/// WebCoordinator itself would create a retain cycle.
final class DevToolsMessageHandler: NSObject, WKScriptMessageHandler {

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "naviDevTools",
              let body = message.body as? [String: Any] else { return }

        let kind = body["kind"] as? String ?? ""
        Task { @MainActor in
            let store = DevToolsStore.shared
            switch kind {
            case "console":
                store.reportConsole(level: body["level"] as? String ?? "log",
                                    message: body["message"] as? String ?? "",
                                    source: nil,
                                    line: nil)
            case "exception":
                store.reportJSException(body["message"] as? String ?? "Script error",
                                        url: nil,
                                        line: nil)
            case "resource":
                let size = (body["size"] as? NSNumber)?.intValue
                let duration = (body["duration"] as? NSNumber)?.intValue
                store.reportResource(method: body["method"] as? String ?? "GET",
                                     url: body["url"] as? String ?? "",
                                     durationMS: duration,
                                     sizeBytes: size)
            default:
                break
            }
        }
    }
}
