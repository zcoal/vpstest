/**
 * 价格两位小数格式化
 * 在 Komari 后台「自定义 JS」中添加
 */
(function () {
  function formatPrices() {
    document.querySelectorAll("p").forEach(function (el) {
      if (el.textContent.indexOf("价格:") === 0) {
        var newText = el.textContent.replace(
          /(价格:\s*[¥$])(\d+(?:\.\d+)?)(\/.+)/,
          function (_, prefix, num, suffix) {
            return prefix + parseFloat(num).toFixed(2) + suffix;
          }
        );
        if (newText !== el.textContent) el.textContent = newText;
      }
    });
  }

  function setup() {
    var target = document.querySelector("#root");
    if (!target) return;
    var scheduled = false;
    new MutationObserver(function () {
      if (!scheduled) {
        scheduled = true;
        requestAnimationFrame(function () {
          scheduled = false;
          formatPrices();
        });
      }
    }).observe(target, { childList: true, subtree: true });
    formatPrices();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", setup);
  } else {
    setup();
  }
  (function poll() {
    if (document.querySelector("#root")) setup();
    else setTimeout(poll, 300);
  })();
})();