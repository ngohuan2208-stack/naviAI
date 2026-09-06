import Foundation
import WebKit

struct ElementInspection: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var tag: String
    var idAttribute: String?
    var classes: [String]
    var attributes: [String: String]
    var text: String
    var parentTag: String?
    var childCount: Int
    var selector: String
    var boundingBox: String

    var displayLabel: String {
        var s = tag
        if let idAttribute, !idAttribute.isEmpty { s += "#\(idAttribute)" }
        if !classes.isEmpty { s += "." + classes.joined(separator: ".") }
        return "<\(s)>"
    }
}

@MainActor
final class DOMInspector {

    weak var coordinator: WebCoordinator?
    private let store: DevToolsStore

    init(store: DevToolsStore = .shared) {
        self.store = store
    }

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

    func refreshStorage() async {
        let raw = try? await coordinator?.evaluate(storageScript)
        guard let value = raw ?? nil, let json = value as? String,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        store.setStorage(local: Self.pairs(from: obj["local"]),
                         session: Self.pairs(from: obj["session"]))
    }

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

    @discardableResult
    func highlight(matchingText text: String) async -> Int {
        let raw = try? await coordinator?.evaluate(highlightScript(text: text))
        guard let value = raw ?? nil else { return 0 }
        return value as? Int ?? 0
    }

    @discardableResult
    func beginElementSelection() async -> Bool {
        guard let raw = try? await coordinator?.evaluate(selectModeStartScript),
              let value = raw ?? nil else { return false }
        return (value as? String) == "started"
    }

    func cancelElementSelection() async {
        _ = try? await coordinator?.evaluate(selectModeStopScript)
        store.setInspectedElement(nil)
    }

    func readSelectedElement() async -> ElementInspection? {
        let raw = try? await coordinator?.evaluate(readPickScript)
        guard let value = raw ?? nil, let json = value as? String,
              let data = json.data(using: .utf8),
              let element = try? JSONDecoder().decode(ElementInspection.self, from: data) else {
            return nil
        }
        store.setInspectedElement(element)
        _ = try? await coordinator?.evaluate("try { window.__naviPicked = null; } catch(e){}")
        return element
    }

    func safeCopySelector(_ element: ElementInspection) -> String {
        Redactor.redactText(element.selector)
    }

    private static func pairs(from any: Any?) -> [(String, String)] {
        guard let dict = any as? [String: Any] else { return [] }
        return dict.map { ($0.key, $0.value as? String ?? String(describing: $0.value)) }
            .sorted { $0.0 < $1.0 }
    }
}

extension DOMInspector {

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

    var storageScript: String {
        """
        (function(){
          function grab(s){ var o={}; for (var i=0;i<s.length;i++){ var k=s.key(i); o[k]=String(s.getItem(k)).slice(0,300);} return o; }
          return JSON.stringify({ local: grab(localStorage), session: grab(sessionStorage) });
        })();
        """
    }

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

    func evaluateUserSnippet(_ code: String) async -> String {
        guard let raw = try? await coordinator?.evaluate(code) else {
            return "⚠️ Evaluation failed or returned nil"
        }
        switch raw {
        case nil: return "undefined"
        case .some(let v): return Redactor.redactText(String(describing: v))
        }
    }

    var selectModeStartScript: String {
        """
        (function(){
          if (window.__naviPickMode) return 'started';
          window.__naviPickMode = true;
          window.__naviPicked = null;
          var hint = document.createElement('div');
          hint.id = 'navi-inspect-hint';
          hint.textContent = 'Navi inspect: tap an element (Esc to cancel)';
          hint.style.cssText = 'position:fixed;top:12px;right:12px;z-index:2147483647;background:#7C6BFF;color:#fff;font:12px -apple-system,system-ui,sans-serif;padding:6px 10px;border-radius:8px;box-shadow:0 2px 10px rgba(0,0,0,.35);pointer-events:none;';
          document.documentElement.appendChild(hint);
          var outline = null;
          function selectorOf(el){
            var path = [], node = el;
            while (node && node.nodeType === 1 && path.length < 6) {
              var p = node.tagName.toLowerCase();
              if (node.id) p += '#' + node.id;
              if (typeof node.className === 'string') {
                var cls = node.className.trim().split(/\\s+/).filter(Boolean).slice(0,2);
                if (cls.length) p += '.' + cls.join('.');
              }
              if (node.parentElement && !node.id) {
                var kids = node.parentElement.children, same = 1;
                for (var i = 0; i < kids.length; i++) {
                  if (kids[i] === node) break;
                  if (kids[i].tagName === node.tagName) same++;
                }
                if (kids.length > 1) p += ':nth-of-type(' + same + ')';
              }
              path.unshift(p);
              if (node.id) break;
              node = node.parentElement;
            }
            return path.join(' > ');
          }
          function describe(el){
            var attrs = {};
            for (var i = 0; i < el.attributes.length; i++) {
              var a = el.attributes[i];
              if (a.name !== 'style') attrs[a.name] = a.value;
            }
            var parentTag = el.parentElement ? el.parentElement.tagName.toLowerCase() : null;
            var r = el.getBoundingClientRect();
            var box = Math.round(r.x) + ',' + Math.round(r.y) + ',' + Math.round(r.width) + ',' + Math.round(r.height);
            var cls = (typeof el.className === 'string') ? el.className.trim().split(/\\s+/).filter(Boolean) : [];
            return JSON.stringify({
              tag: el.tagName.toLowerCase(),
              id: el.id || null,
              classes: cls,
              attributes: attrs,
              text: (el.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 200),
              parentTag: parentTag,
              childCount: el.children.length,
              selector: selectorOf(el),
              boundingBox: box
            });
          }
          function onTap(e){
            e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation();
            var target = e.target;
            if (outline) outline.remove();
            outline = document.createElement('div');
            outline.id = 'navi-inspect-outline';
            outline.style.cssText = 'position:absolute;z-index:2147483646;pointer-events:none;outline:2px solid #7C6BFF;background:rgba(124,107,255,0.12);';
            var r = target.getBoundingClientRect();
            outline.style.left = (r.x + window.scrollX) + 'px';
            outline.style.top = (r.y + window.scrollY) + 'px';
            outline.style.width = r.width + 'px';
            outline.style.height = r.height + 'px';
            document.documentElement.appendChild(outline);
            window.__naviPicked = describe(target);
            finish();
          }
          function finish(){
            window.__naviPickMode = false;
            if (hint && hint.parentNode) hint.remove();
            document.removeEventListener('click', onTap, true);
            document.removeEventListener('keydown', onKey, true);
            if (outline) setTimeout(function(){ if (outline && outline.parentNode) outline.remove(); }, 3000);
          }
          function onKey(e){ if (e.key === 'Escape') finish(); }
          document.addEventListener('click', onTap, true);
          document.addEventListener('keydown', onKey, true);
          return 'started';
        })();
        """
    }

    var selectModeStopScript: String {
        """
        (function(){
          window.__naviPickMode = false;
          var h = document.getElementById('navi-inspect-hint');
          if (h && h.parentNode) h.remove();
          var o = document.getElementById('navi-inspect-outline');
          if (o && o.parentNode) o.remove();
          return true;
        })();
        """
    }

    var readPickScript: String {
        "window.__naviPicked || ''"
    }

    func refreshAll() async {
        await refreshDOM()
        await refreshStorage()
        await refreshCookies()
    }
}
