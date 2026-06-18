/**
 * Komari 延迟图展示脚本
 * 将 "详情" 和 "网络" 两个标签页内容同时显示在网络详情下方
 * 用法：在 Komari 页面通过 <script> 引入，或粘贴到 custom HTML injection
 *
 * 基于 zcoal/vpstest 的 vps-show-ping.js 修改，适配 Komari 面板
 */
(function () {
  // ============ 选择器配置 ============
  // 标签容器（Komari 和哪吒都用 .server-info-tab）
  const selectorTabWrap = "#root .server-info-tab";

  // 详情区和网络区 —— 用 .server-info 相对路径，不再硬编码完整 DOM 树
  const selectorDetail = ".server-info > div:nth-child(3)";
  const selectorNetwork = ".server-info > div:nth-child(4)";

  let scheduled = false;
  let clickedNet = false;
  let retry = 0;
  const MAX_RETRY = 30;

  /**
   * 通过标签文字找到对应的 tab 元素并点击
   */
  function getTabByText(text) {
    const wrap = document.querySelector(selectorTabWrap);
    if (!wrap) return null;
    const tabs = wrap.querySelectorAll(".cursor-pointer");
    for (const el of tabs) {
      const label = (
        el.querySelector("p")?.textContent ||
        el.textContent ||
        ""
      ).trim();
      if (label === text) return el;
    }
    return null;
  }

  /**
   * 隐藏标签切换栏（不再显示 "详情/网络" 切换按钮）
   */
  function hideTabSection() {
    const wrap = document.querySelector(selectorTabWrap);
    if (!wrap) return;
    const section = wrap.closest("section");
    if (section) section.style.display = "none";
  }

  /**
   * 强制详情区和网络区同时可见
   */
  function forceBothVisible() {
    const detail = document.querySelector(selectorDetail);
    const network = document.querySelector(selectorNetwork);

    if (detail) {
      detail.style.display = "block";
      detail.style.marginTop = "20px";
    }
    if (network) {
      network.style.display = "block";
      network.style.marginTop = "20px";
    }
  }

  /**
   * 检测网络/延迟图是否已加载
   */
  function networkSeemsLoaded() {
    const root = document.querySelector("#root");
    if (!root) return false;

    const text = root.innerText || "";
    if (
      text.includes("网络") &&
      (text.includes("上行") ||
        text.includes("下行") ||
        text.includes("延迟") ||
        text.includes("流量") ||
        text.includes("ms") ||
        text.includes("avg loss"))
    ) {
      return true;
    }

    if (root.querySelector(".recharts-wrapper, svg.recharts-surface, canvas")) {
      return true;
    }

    return false;
  }

  /**
   * 如果还没有加载网络数据，点击 "网络" 标签
   */
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

  /**
   * 判断当前是否在服务器详情页
   */
  function isOnServerInfoPage() {
    return !!document.querySelector(selectorTabWrap);
  }

  /**
   * 主循环：MutationObserver 每次变化时触发
   */
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
