import Foundation
import WebKit

// MARK: - DOM inspector bridge

/// Runs inspection JavaScript in the page and feeds results to DevToolsStore.
/// Uses ONLY public WKWebView APIs (evaluateJavaScript) — no private selectors.
@MainActor
final class DOMInspector {

    weak var coordinator: WebCoordinator?
    private let store: DevToolsStore

    init(store: DevToolsStore = .shared) {
        self.store = store
    }

    // MARK: Public API

    /// Collects a flattened, size-limited summary of interactive + structural
    /// elements. Cheap enough to run on demand from the inspector UI.
    func refreshDOM() async {
        let raw = try? await coordinator?.evaluate(domSummaryScript)
        guard let value = raw ?? nil, let json = value as? String,
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let summaries: [DevDOMSummary] = arr.compactMap { dict in
            guard let tag = dict["tag"] as? String else { return nil }
            return DevDOMSummary(
                tag: tag,
                idAttribute: dict["id"] as? String,
                classes: dict["cls"] as? String,
                textPreview: (dict["txt"] as? String).map { String($0.prefix(80)) },
                childCount: dict["kids"] as? Int ?? 0,
                depth: dict["depth"] as? Int ?? 0)
        }
        store.setDOMSummaries(summaries)
    }

    /// Fetch localStorage + sessionStorage (values redacted by the store).
    func refreshStorage() async {
        let raw = try? await coordinator?.evaluate(storageScript)
        guard let value = raw ?? nil, let json = value as? String,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        store.setStorage(local: Self.pairs(from: obj["local"]),
                         session: Self.pairs(from: obj["session"]))
    }

    /// Cookie count via document.cookie (length-aware, no values kept).
    func refreshCookies() async {
        let raw = try? await coordinator?.evaluate("document.cookie")
        guard let value = raw ?? nil else {
            store.setCookies(count: 0)
            return
        }
        let text = value as? String ?? ""
        let count = text.isEmpty ? 0 : text.split(separator: ";").count
        store.setCookies(count: count)
    }

    /// Highlight elements containing `text`; returns how many were outlined.
    @discardableResult
    func highlight(matchingText text: String) async -> Int {
        let raw = try? await coordinator?.evaluate(highlightScript(text: text))
        guard let value = raw ?? nil else { return 0 }
        return value as? Int ?? 0
    }

    private static func pairs(from any: Any?) -> [(String, String)] {
        guard let dict = any as? [String: Any] else { return [] }
        return dict.map { ($0.key, $0.value as? String ?? String(describing: $0.value)) }
            .sorted { $0.0 < $1.0 }
    }
}

// MARK: - JS snippets & evaluation

extension DOMInspector {

    /// Flattened summary of visible interactive/structural elements.
    var domSummaryScript: String {
        """
        (function(){
          var out = [];
          var sel = 'a,button,input,select,textarea,form,nav,header,footer,main,section,article,[role=button],[role=dialog]';
          var nodes = document.querySelectorAll(sel);
          for (var i = 0; i < nodes.length && out.length < 150; i++) {
            var el = nodes[i];
            var r = el.getBoundingClientRect();
            if (r.width === 0 && r.height === 0) continue;
            var depth = 0, p = el.parentElement;
            while (p) { depth++; p = p.parentElement; }
            var cls = null;
            if (typeof el.className === 'string') cls = el.className;
            else if (el.className && el.className.baseVal !== undefined) cls = el.className.baseVal;
            out.push({
              tag: el.tagName.toLowerCase(),
              id: el.id || null,
              cls: cls,
              txt: (el.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 80),
              kids: el.children.length,
              depth: depth
            });
          }
          return JSON.stringify(out);
        })();
        """
    }

    /// localStorage + sessionStorage dump (truncated per value).
    var storageScript: String {
        """
        (function(){
          function grab(s){ var o={}; for (var i=0;i<s.length;i++){ var k=s.key(i); o[k]=String(s.getItem(k)).slice(0,300);} return o; }
          return JSON.stringify({ local: grab(localStorage), session: grab(sessionStorage) });
        })();
        """
    }

    /// Outline elements whose text matches `text` (case-insensitive).
    func highlightScript(text: String) -> String {
        var escaped = text
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "'", with: "\\'")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        return """
        (function(){
          var q = '\(escaped)';
          if (!q) return 0;
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
          var count = 0, node;
          while ((node = walker.nextNode()) && count < 20) {
            if (node.textContent.toLowerCase().indexOf(q.toLowerCase()) !== -1) {
              var span = document.createElement('span');
              span.setAttribute('data-naviai-hl', '1');
              span.style.outline = '2px solid #7C6BFF';
              span.style.backgroundColor = 'rgba(124,107,255,0.18)';
              node.parentNode.insertBefore(span, node);
              span.appendChild(node);
              count++;
            }
          }
          return count;
        })();
        """
    }

    /// Evaluate a user-provided snippet in page context. The RESULT is
    /// redacted by this method before it is returned for display.
    func evaluateUserSnippet(_ code: String) async -> String {
        guard let raw = try? await coordinator?.evaluate(code) else {
            return "⚠️ Evaluation failed or returned nil"
        }
        switch raw {
        case nil: return "undefined"
        case .some(let v): return Redactor.redactText(String(describing: v))
        }
    }

    /// Refresh all page-derived data at once.
    func refreshAll() async {
        await refreshDOM()
        await refreshStorage()
        await refreshCookies()
    }
}