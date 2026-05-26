(function() {
  const style = document.createElement("style");

  style.textContent = `
    .probe-compact-tabs {
      flex-wrap: nowrap !important;
    }

    .probe-compact-tabs > button {
      flex: 1 1 0 !important;
      min-width: 0 !important;
      padding-left: 8px !important;
      padding-right: 8px !important;
    }

    .probe-compact-tabs > button span {
      white-space: nowrap !important;
      overflow: hidden !important;
      text-overflow: ellipsis !important;
    }

    .probe-compact-tabs > button .flex.items-center {
      gap: 4px !important;
      white-space: nowrap !important;
    }
  `;

  document.head.appendChild(style);

  function applyProbeCompactLayout() {
    document.querySelectorAll(".rounded-t-lg > .flex.flex-wrap.w-full").forEach((tabs) => {
      const buttons = tabs.querySelectorAll(":scope > button");

      if (buttons.length >= 6) {
        tabs.classList.add("probe-compact-tabs");
      } else {
        tabs.classList.remove("probe-compact-tabs");
      }
    });
  }

  applyProbeCompactLayout();

  new MutationObserver(applyProbeCompactLayout).observe(document.body, {
    childList: true,
    subtree: true,
  });
})();