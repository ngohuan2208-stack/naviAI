import Foundation

// MARK: - DOM snapshot models (mirror of the JSON the injected JS returns)

struct DOMRectInfo: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    var centerX: Double { x + w / 2 }
    var centerY: Double { y + h / 2 }
}

struct DOMItemInfo: Codable, Equatable {
    var id: Int
    var tag: String
    var text: String
    var name: String
    var placeholder: String
    var aria: String
    var type: String
    var href: String
    var role: String
    var submit: Bool
    var input: Bool
    var rect: DOMRectInfo

    /// Free-text description used when talking to the model.
    var summary: String {
        var parts: [String] = []
        if !text.isEmpty { parts.append("text: \(text)") }
        if !placeholder.isEmpty { parts.append("placeholder: \(placeholder)") }
        if !aria.isEmpty { parts.append("aria: \(aria)") }
        if !name.isEmpty { parts.append("name: \(name)") }
        if !href.isEmpty { parts.append("href: \(href)") }
        return parts.joined(separator: ", ")
    }
}

struct DOMSnapshot: Codable, Equatable {
    var url: String
    var title: String
    var bodyText: String
    var viewportWidth: Double
    var viewportHeight: Double
    var devicePixelRatio: Double
    var items: [DOMItemInfo]
}

struct DOMClickResult: Codable, Equatable {
    var ok: Bool
    var error: String?
    var item: DOMItemInfo?
    var atX: Double?
    var atY: Double?

    enum CodingKeys: String, CodingKey {
        case ok, error, item
        case atX = "x"
        case atY = "y"
    }
}

enum BrowserJavaScript {

    /// User-facing heuristic flags gathered from the live page.
    struct PageSignals: Codable, Equatable {
        var hasCaptchaFrame: Bool
        var bodyHint: String
    }

    // MARK: - Core injected script

    /// This is injected at document-start into the main frame of every page.
    /// It installs a small DOM interaction engine on window.__navi. It never
    /// bypasses CAPTCHAs - it only reports them so the agent can pause.
    static let coreScript: String = """
    (function () {
      if (window.__navi) { return; }
      var map = {};
      var seq = 0;

      function isInteractive(el) {
        if (!el || el.nodeType !== 1) { return false; }
        var t = el.nodeName;
        if (t === 'A' || t === 'BUTTON' || t === 'INPUT' || t === 'TEXTAREA' || t === 'SELECT') { return true; }
        if (el.hasAttribute('onclick')) { return true; }
        if (el.isContentEditable) { return true; }
        var role = el.getAttribute('role');
        return role === 'button' || role === 'link' || role === 'checkbox' || role === 'switch' ||
               role === 'menuitem' || role === 'tab' || role === 'option' || role === 'searchbox';
      }

      function isVisible(el) {
        if (!el || el.nodeType !== 1) { return false; }
        if (el === document.body || el === document.documentElement) { return true; }
        var st;
        try { st = window.getComputedStyle(el); } catch (e) { return false; }
        if (st.display === 'none' || st.visibility === 'hidden') { return false; }
        var r = el.getBoundingClientRect();
        if (r.width <= 1 && r.height <= 1) {
          var t = el.nodeName;
          if (!(t === 'A' || t === 'INPUT' || t === 'BUTTON' || t === 'TEXTAREA' || t === 'SELECT')) { return false; }
        }
        return true;
      }

      function normText(s) {
        if (!s) { return ''; }
        s = String(s);
        var out = '', ws = false;
        for (var i = 0; i < s.length; i++) {
          var c = s.charAt(i);
          if (c === ' ' || c === '\\n' || c === '\\t' || c === '\\r' || c === '\\u00a0') {
            if (!ws) { out += ' '; ws = true; }
          } else { out += c; ws = false; }
        }
        return out.trim();
      }

      function textOf(el) {
        if (!el) { return ''; }
        var t = el.nodeName;
        if (t === 'INPUT' || t === 'TEXTAREA') {
          return el.placeholder || el.getAttribute('aria-label') || el.getAttribute('label') || '';
        }
        return normText(el.innerText || el.textContent || '');
      }

      function truncate(s, n) { return s.length > n ? s.slice(0, n) + '...' : s; }

      function submitLikely(el) {
        var t = el.nodeName;
        if (t === 'INPUT' && el.type === 'submit') { return true; }
        if (t === 'BUTTON') {
          var bt = el.getAttribute('type');
          if (bt === null || bt === '' || bt === 'submit') { return true; }
          return false;
        }
        return false;
      }

      function buildItem(el) {
        var id = ++seq;
        map[id] = el;
        var r = el.getBoundingClientRect();
        return {
          id: id,
          tag: el.nodeName.toLowerCase(),
          text: truncate(textOf(el), 200),
          name: el.getAttribute('name') || '',
          placeholder: el.getAttribute('placeholder') || '',
          aria: el.getAttribute('aria-label') || '',
          type: el.getAttribute('type') || '',
          href: el.getAttribute('href') || '',
          role: el.getAttribute('role') || '',
          submit: submitLikely(el),
          input: (el.nodeName === 'INPUT' || el.nodeName === 'TEXTAREA' || el.nodeName === 'SELECT' || el.isContentEditable),
          rect: { x: r.left, y: r.top, w: r.width, h: r.height }
        };
      }

      function interactiveSelector() {
        return 'a[href],button,input,textarea,select,[role="button"],[role="link"],[role="checkbox"],[role="switch"],[role="menuitem"],[role="tab"],[role="option"],[role="searchbox"],[contenteditable="true"],summary,[onclick]';
      }

      function snapshot(maxItems) {
        if (!maxItems) { maxItems = 80; }
        map = {}; seq = 0;
        var els = document.querySelectorAll(interactiveSelector());
        var items = [];
        for (var i = 0; i < els.length; i++) {
          var el = els[i];
          if (!isVisible(el)) { continue; }
          items.push(buildItem(el));
          if (items.length >= maxItems) { break; }
        }
        var body = document.body ? textOf(document.body) : '';
        if (body.length > 12000) { body = body.slice(0, 12000); }
        var vw = document.documentElement.clientWidth;
        var vh = document.documentElement.clientHeight;
        return JSON.stringify({
          url: location.href,
          title: document.title || location.href,
          bodyText: body,
          viewportWidth: vw,
          viewportHeight: vh,
          devicePixelRatio: window.devicePixelRatio || 1,
          items: items
        });
      }

      function resolve(id) {
        var el = map[id];
        return (el && el.isConnected) ? el : null;
      }

      function scrollToEl(el) {
        try { el.scrollIntoView({ block: 'center', inline: 'center' }); }
        catch (e) { try { el.scrollIntoView(); } catch (e2) {} }
      }

      function effective(el) {
        if (isInteractive(el)) { return el; }
        var inner = el.querySelector('a[href],button,input,textarea,select,[role="button"],[role="link"],[contenteditable="true"]');
        if (inner && isVisible(inner)) { return inner; }
        var p = el;
        for (var i = 0; i < 6; i++) {
          p = p.parentElement;
          if (!p) { break; }
          if (isInteractive(p)) { return p; }
        }
        return el;
      }

      function locate(id) {
        var el = resolve(id);
        if (!el) { return JSON.stringify({ ok: false, error: 'element no longer in DOM' }); }
        var target = effective(el);
        scrollToEl(target);
        var r = target.getBoundingClientRect();
        return JSON.stringify({ ok: true, item: buildItem(target), x: r.left + r.width / 2, y: r.top + r.height / 2 });
      }

      function firePointer(el, cx, cy) {
        var opts = { bubbles: true, cancelable: true, view: window, clientX: cx, clientY: cy };
        try {
          el.dispatchEvent(new MouseEvent('mouseover', opts));
          el.dispatchEvent(new MouseEvent('pointerdown', opts));
          el.dispatchEvent(new MouseEvent('mousedown', opts));
          el.dispatchEvent(new MouseEvent('pointerup', opts));
          el.dispatchEvent(new MouseEvent('mouseup', opts));
        } catch (e) {}
      }

      function click(id) {
        var el = resolve(id);
        if (!el) { return JSON.stringify({ ok: false, error: 'element is no longer in the page. Re-read the page and try again.' }); }
        var target = effective(el);
        scrollToEl(target);
        try { if (typeof target.focus === 'function') { target.focus({ preventScroll: true }); } } catch (e) {}
        var r = target.getBoundingClientRect();
        var cx = r.left + r.width / 2;
        var cy = r.top + r.height / 2;
        var tag = target.nodeName;
        firePointer(target, cx, cy);
        if (tag === 'A' || tag === 'SELECT') {
          try { target.click(); } catch (e) {}
        } else if (target.type === 'submit' || submitLikely(target)) {
          try { target.click(); } catch (e) {}
        } else {
          try {
            target.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window, clientX: cx, clientY: cy }));
            target.click();
          } catch (e) {
            try { target.click(); } catch (e2) {}
          }
        }
        var item = buildItem(target);
        return JSON.stringify({ ok: true, item: item, x: cx, y: cy, clickedTag: tag });
      }

      function setValue(el, val) {
        var proto = (el.nodeName === 'TEXTAREA')
          ? window.HTMLTextAreaElement.prototype
          : window.HTMLInputElement.prototype;
        var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
        setter.call(el, val);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }

      function type(id, text, enter) {
        var el = resolve(id);
        if (!el) { return JSON.stringify({ ok: false, error: 'element is no longer in the page. Re-read the page and try again.' }); }
        var target = effective(el);
        if (target.nodeName !== 'INPUT' && target.nodeName !== 'TEXTAREA' && !target.isContentEditable) {
          var inner = target.querySelector('input,textarea,[contenteditable="true"]');
          if (inner) { target = inner; }
        }
        if (target.nodeName !== 'INPUT' && target.nodeName !== 'TEXTAREA' && !target.isContentEditable) {
          return JSON.stringify({ ok: false, error: 'target is not a text field' });
        }
        scrollToEl(target);
        try { target.focus({ preventScroll: true }); } catch (e) {}
        var textVal = String(text || '');
        if (target.isContentEditable) {
          try {
            document.execCommand('selectAll', false, null);
            document.execCommand('insertText', false, textVal);
            target.dispatchEvent(new Event('input', { bubbles: true }));
          } catch (e) {
            target.textContent = textVal;
          }
        } else {
          setValue(target, textVal);
        }
        var submitted = false;
        if (enter && textVal.indexOf('\\n') === -1) {
          try {
            var form = target.form;
            if (form) {
              if (typeof form.requestSubmit === 'function') { form.requestSubmit(); submitted = true; }
            }
          } catch (e) {}
          if (!submitted) {
            try {
              target.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true }));
              target.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', bubbles: true }));
            } catch (e) {}
          }
        }
        var r = target.getBoundingClientRect();
        return JSON.stringify({ ok: true, x: r.left + r.width / 2, y: r.top + r.height / 2, submitted: submitted, len: textVal.length });
      }

      function clickAt(x, y) {
        var el = document.elementFromPoint(x, y);
        if (!el) { return JSON.stringify({ ok: false, error: 'nothing found at that point' }); }
        if (el === document.body || el === document.documentElement) {
          return JSON.stringify({ ok: false, error: 'not an actionable element at that point' });
        }
        var target = effective(el);
        var id = ++seq;
        map[id] = target;
        return click(id);
      }

      function findText(query, max) {
        if (!max) { max = 8; }
        map = {}; seq = 0;
        var q = String(query || '').toLowerCase();
        if (!q) { return JSON.stringify({ items: [] }); }
        var out = [];
        var all = document.querySelectorAll('a[href],button,input,textarea,select,[role="button"],[role="link"],p,h1,h2,h3,h4,li,summary,[aria-label],[contenteditable="true"]');
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          if (!isVisible(el)) { continue; }
          var t = textOf(el).toLowerCase();
          if (t.indexOf(q) !== -1) {
            out.push(buildItem(el));
            if (out.length >= max) { break; }
          }
        }
        return JSON.stringify({ items: out });
      }

      function scrollBy(dx, dy) {
        var x = typeof dx === 'number' ? dx : 0;
        var y = typeof dy === 'number' ? dy : 0;
        window.scrollBy(x, y);
        return JSON.stringify({ x: window.scrollX, y: window.scrollY });
      }

      function scrollToId(id, block) {
        var el = resolve(id);
        if (!el) { return JSON.stringify({ ok: false }); }
        scrollToEl(el);
        return JSON.stringify({ ok: true });
      }

      function readText(maxChars) {
        if (!maxChars) { maxChars = 12000; }
        var body = document.body ? textOf(document.body) : '';
        if (body.length > maxChars) { body = body.slice(0, maxChars); }
        return JSON.stringify({ url: location.href, title: document.title, text: body });
      }

      function signals() {
        var hasCaptchaFrame = false;
        var frames = document.querySelectorAll('iframe');
        var hints = [];
        for (var i = 0; i < frames.length; i++) {
          var src = frames[i].getAttribute('src') || '';
          var lc = src.toLowerCase();
          if (lc.indexOf('recaptcha') !== -1 || lc.indexOf('hcaptcha') !== -1 ||
              lc.indexOf('captcha') !== -1 || lc.indexOf('turnstile') !== -1 ||
              lc.indexOf('cf-challenge') !== -1) {
            hasCaptchaFrame = true;
          }
        }
        var bodyHint = '';
        var bodyTxt = document.body ? textOf(document.body).toLowerCase() : '';
        var markers = ['verify you are human', 'captcha', 'security check', 'are you human', 'challenge'];
        for (var j = 0; j < markers.length; j++) {
          if (bodyTxt.indexOf(markers[j]) !== -1) { bodyHint = markers[j]; break; }
        }
        return JSON.stringify({ hasCaptchaFrame: hasCaptchaFrame, bodyHint: bodyHint });
      }

      function info() {
        return JSON.stringify({
          ready: document.readyState,
          url: location.href,
          title: document.title || '',
          vw: document.documentElement.clientWidth,
          vh: document.documentElement.clientHeight
        });
      }

      window.__navi = {
        snapshot: snapshot,
        locate: locate,
        click: click,
        clickAt: clickAt,
        type: type,
        findText: findText,
        scrollBy: scrollBy,
        scrollToId: scrollToId,
        readText: readText,
        signals: signals,
        info: info
      };
    })();
    """

    // MARK: - Expression helpers

    static func call(_ fn: String, args: [String]) -> String {
        "JSON.parse(" + "window.__navi.\(fn)(\(args.joined(separator: ",")))" + ")"
    }

    static func snapshotExpr(maxItems: Int = 80) -> String {
        "window.__navi.snapshot(\(maxItems))"
    }

    static func locateExpr(id: Int) -> String {
        "window.__navi.locate(\(id))"
    }

    static func clickExpr(id: Int) -> String {
        "window.__navi.click(\(id))"
    }

    static func typeExpr(id: Int, text: String, enter: Bool) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "window.__navi.type(\(id), \"\(escaped)\", \(enter ? "true" : "false"))"
    }

    static func clickAtExpr(x: Double, y: Double) -> String {
        "window.__navi.clickAt(\(Int(x)), \(Int(y)))"
    }

    static func findTextExpr(query: String, max: Int = 8) -> String {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "window.__navi.findText(\"\(escaped)\", \(max))"
    }

    static func scrollByExpr(dx: Int, dy: Int) -> String {
        "window.__navi.scrollBy(\(dx), \(dy))"
    }

    static func scrollToIdExpr(id: Int) -> String {
        "window.__navi.scrollToId(\(id), \"center\")"
    }

    static func readTextExpr(maxChars: Int = 12000) -> String {
        "window.__navi.readText(\(maxChars))"
    }

    static func signalsExpr() -> String {
        "window.__navi.signals()"
    }

    static func infoExpr() -> String {
        "window.__navi.info()"
    }
}
