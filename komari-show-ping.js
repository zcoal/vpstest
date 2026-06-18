/**
 * Komari 延迟图 — 同时显示详情+网络延迟
 * 在 Komari 后台「自定义 JS」中添加
 */
(function () {
  var STYLE_ID = "komari-dual-view";
  var CSS = '.server-info > div:nth-child(3),.server-info > div:nth-child(4){display:block!important;margin-top:20px}.server-info > section:has(.server-info-tab){display:none!important}';

  function injectCSS() {
    if (document.getElementById(STYLE_ID)) return;
    var s = document.createElement("style");
    s.id = STYLE_ID;
    s.textContent = CSS;
    document.head.appendChild(s);
  }

  function getTab(text) {
    var w = document.querySelector("#root .server-info-tab");
    if (!w) return null;
    var tabs = w.querySelectorAll(".cursor-pointer");
    for (var i = 0; i < tabs.length; i++) {
      if ((tabs[i].querySelector("p") || tabs[i]).textContent.trim() === text) return tabs[i];
    }
    return null;
  }

  var clicked = false, retries = 0;

  function tick() {
    var infoPage = !!document.querySelector("#root .server-info-tab");
    if (infoPage) {
      injectCSS();
      if (!clicked && retries < 30) {
        var tab = getTab("网络");
        if (tab) { tab.click(); clicked = true; retries++; }
      }
    } else {
      clicked = false; retries = 0;
    }
  }

  function setup() {
    var root = document.querySelector("#root");
    if (!root) return;
    var scheduled = false;
    new MutationObserver(function () {
      if (!scheduled) { scheduled = true; requestAnimationFrame(function () { scheduled = false; tick(); }); }
    }).observe(root, { childList: true, subtree: true, attributes: true, attributeFilter: ["class", "style"] });
    tick();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", setup);
  } else {
    setup();
  }
  (function poll() {
    if (!document.getElementById(STYLE_ID)) { setup(); setTimeout(poll, 300); }
  })();
})();
