(function() {
  const selectorTabWrap = "#root .server-info-tab";
  const selector3 =
    "#root > div > main > div.mx-auto.w-full.max-w-5xl.px-0.flex.flex-col.gap-4.server-info > div:nth-child(3)";
  const selector4 =
    "#root > div > main > div.mx-auto.w-full.max-w-5xl.px-0.flex.flex-col.gap-4.server-info > div:nth-child(4)";
  const selectorTimeTab =
    "#root > div > main > div.mx-auto.w-full.max-w-5xl.px-0.flex.flex-col.gap-4.server-info > div .time-tab"; // 假设这是“实时 1天 7天 30天”的容器

  let scheduled = false;
  let clickedNet = false;
  let retry = 0;
  const MAX_RETRY = 30;

  function getTabByText(text) {
    const wrap = document.querySelector(selectorTabWrap);
    if (!wrap) return null;
    const tabs = wrap.querySelectorAll(".cursor-pointer");
    for (const el of tabs) {
      const label = (el.querySelector("p")?.textContent || el.textContent || "").trim();
      if (label === text) return el;
    }
    return null;
  }

  function hideTabSection() {
    const wrap = document.querySelector(selectorTabWrap);
    if (!wrap) return;
    const section = wrap.closest("section");
    if (section) section.style.display = "none";
  }

  function forceBothVisible() {
    const div3 = document.querySelector(selector3);
    const div4 = document.querySelector(selector4);
    const timeTab = document.querySelector(selectorTimeTab);

    if (div3) {
      div3.style.display = "block";
      div3.style.marginTop = "20px";  // 增加底部间距
    }
    if (div4) {
      div4.style.display = "block";
      div4.style.marginTop = "20px";  // 增加顶部间距
    }
  }

  function networkSeemsLoaded() {
    const root = document.querySelector("#root");
    if (!root) return false;

    const text = root.innerText || "";
    if (
      text.includes("网络") &&
      (text.includes("上行") || text.includes("下行") || text.includes("延迟") || text.includes("流量"))
    ) {
      return true;
    }

    if (root.querySelector(".recharts-wrapper, svg.recharts-surface, canvas")) {
      return true;
    }

    return false;
  }

  function clickNetIfNeeded() {
    if (clickedNet && networkSeemsLoaded()) return;
    if (retry >= MAX_RETRY) return;

    const netTab = getTabByText("网络");
    if (netTab) {
      netTab.click();
      clickedNet = true;
      retry++;
    }
  }

  function isOnServerInfoPage() {
    return !!document.querySelector("#root .server-info-tab");
  }

  function tick() {
    scheduled = false;

    const nowInPage = isOnServerInfoPage();

    if (nowInPage) {
      hideTabSection();
      clickNetIfNeeded();

      setTimeout(forceBothVisible, 800);
      forceBothVisible();
    } else {
      clickedNet = false;
      retry = 0;
    }
  }

  const root = document.querySelector("#root");
  if (!root) return;

  const ob = new MutationObserver(() => {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(tick);
  });

  ob.observe(root, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["class", "style"],
  });

  tick();
})();