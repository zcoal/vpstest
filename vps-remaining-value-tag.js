(function() {
  'use strict';
  
  // 添加CSS样式
  const style = document.createElement('style');
  style.textContent = `
    .vps-value-tag {
      font-size: 9px;
      font-weight: 600;
      padding: 1.5px 3px;
      border-radius: 5px;
      margin: 0;
    }
    
    .vps-value-tag.excellent { color: #10b981; background: rgba(16, 185, 129, 0.15); }
    .vps-value-tag.good { color: #22c55e; background: rgba(34, 197, 94, 0.15); }
    .vps-value-tag.moderate { color: #f59e0b; background: rgba(245, 158, 11, 0.15); }
    .vps-value-tag.low { color: #ef4444; background: rgba(239, 68, 68, 0.15); }
    .vps-value-tag.very-low { color: #dc2626; background: rgba(220, 38, 38, 0.15); }
    .vps-value-tag.expired { color: #9ca3af; background: rgba(156, 163, 175, 0.15); }
    
    .dark .vps-value-tag { background-opacity: 0.25; }
  `;
  document.head.appendChild(style);
  
  // 配置
  const CONFIG = { tagText: '剩余', tagPosition: 'last', currency: '$' };
  const EXPIRED_KEYWORDS = ['已过期', '已到期', '过期', '到期'];
  
  // 支持的货币符号
  const CURRENCY_SYMBOLS = ['HK$', 'US$', 'C$', 'A$', '€', '£', '¥', '￥', '$'];
  
  // 主处理函数
  function processVPS() {
    // [FIX] 新版哪吒探针去掉了 border 类，改用 ring，所以选择器改为 .rounded-lg.bg-card
    document.querySelectorAll('.rounded-lg.bg-card').forEach(card => {
      try {
        // 每次都重新处理，移除已存在的标签
        removeExistingTag(card);
        
        const text = card.textContent;
        const price = extractPrice(text);
        
        if (!price || price.free || price.oneTime) {
          return;
        }
        
        if (checkExpired(text)) {
          addTag(card, CONFIG.currency + '0.00', 'expired', { ...price, expired: true });
          return;
        }
        
        const days = extractDays(text);
        if (!days || days === Infinity) {
          return;
        }
        
        const remaining = calculateRemaining(price.value, days, price.period);
        if (remaining === null || remaining === Infinity) {
          return;
        }
        
        const display = (price.symbol || CONFIG.currency) + remaining.toFixed(2);
        const valueStyle = getValueStyle(remaining, price.value);
        
        addTag(card, display, valueStyle, { ...price, days, remaining });
        
      } catch (e) { console.warn('VPS处理出错:', e, card); }
    });
  }
  
  // 移除已存在的标签
  function removeExistingTag(card) {
    const existingTag = card.querySelector('.vps-value-tag');
    if (existingTag) {
      existingTag.remove();
    }
  }
  
  // 提取价格信息（修复版：兼容空格、多类型符号和独立周期行）
  function extractPrice(text) {
    // 一次性付费
    const oneTimeMatch = text.match(/价格:\s*([^\/\n]+)\/(-|一次性)/);
    if (oneTimeMatch) return parsePrice(oneTimeMatch[1], true);
    
    // 免费
    if (text.match(/价格:\s*(免费|Free|0)/i)) return { free: true };
    
    // 正常价格：容忍空格和前后字母（如 "$100 / 年付"，"100USD/年"）
    const normalMatch = text.match(/价格:\s*([^\/\n]+)(?:\s*\/\s*([^\s\n]+))?/);
    if (normalMatch) {
      let priceStr = normalMatch[1].trim();
      let periodStr = normalMatch[2]; 
      
      let period = '月'; // 默认月付
      
      // 1. 优先看斜杠后面的周期
      if (periodStr) {
        if (periodStr.match(/三年|三年付|三年度|3年|3\s*year|three[\s-]?year|triennial(?:ly)?/i)) period = '三年';
        else if (periodStr.match(/两年|二年|两年付|二年付|两年度|二年度|2年|2\s*year|two[\s-]?year|biennial(?:ly)?/i)) period = '两年';
        else if (periodStr.match(/半年|半年付|half[\s-]?year|semi[\s-]?annual(?:ly)?|semiannually/i)) period = '半年';
        else if (periodStr.match(/年|年付|年度|annually|annual|yearly|\byear\b|\byr\b|\/y\b/i)) period = '年';
        else if (periodStr.match(/季|季付|季度|quarter(?:ly)?|season(?:al(?:ly)?)?/i)) period = '季';
      } 
      // 2. 如果斜杠后没写周期，在整个卡片文本里找线索（应对配置里单独选了计费周期的情况）
      else {
        if (text.match(/周期[:：]?\s*(三年|三年付|三年度|3年)|三年付|三年度|3年|3\s*year|three[\s-]?year|triennial(?:ly)?/i)) period = '三年';
        else if (text.match(/周期[:：]?\s*(两年|二年|两年付|二年付|两年度|二年度|2年)|两年付|二年付|两年度|二年度|2年|2\s*year|two[\s-]?year|biennial(?:ly)?/i)) period = '两年';
        else if (text.match(/周期[:：]?\s*(半年|半年付|半年度)|半年付|半年度|half[\s-]?year|semi[\s-]?annual(?:ly)?|semiannually/i)) period = '半年';
        else if (text.match(/周期[:：]?\s*(一?年|年付|年度)|年付|年度|annually|annual|yearly|\byear\b|\byr\b/i)) period = '年';
        else if (text.match(/周期[:：]?\s*(一?季|季付|季度)|季付|季度|quarter(?:ly)?|season(?:al(?:ly)?)?/i)) period = '季';
      }
      
      return parsePrice(priceStr, false, period);
    }
    
    return null;
  }
  
  // 解析价格
  function parsePrice(str, oneTime = false, period = '月') {
    let symbol = CONFIG.currency;
    
    // 检查是否包含已知货币符号
    for (const currency of CURRENCY_SYMBOLS) {
      if (str.includes(currency)) {
        symbol = currency;
        break;
      }
    }
    // 补充常见字母型货币兜底
    if (str.match(/USD/i)) symbol = '$';
    if (str.match(/CNY|RMB/i)) symbol = '￥';
    if (str.match(/EUR/i)) symbol = '€';
    
    // 清理字符串，精准提取纯数字（应对 100USD 紧贴在一起的情况）
    const numMatch = str.replace(/,/g, '').match(/[\d.]+/);
    const value = numMatch ? parseFloat(numMatch[0]) : 0;
    
    // 转换内部周期格式
    let periodType = 'month';
    if (period === '三年') periodType = 'three-year';
    else if (period === '两年') periodType = 'two-year';
    else if (period === '年') periodType = 'year';
    else if (period === '半年') periodType = 'half-year';
    else if (period === '季') periodType = 'quarter';
    
    return {
      value, 
      symbol,
      free: false,
      oneTime,
      period: periodType
    };
  }
  
  // 检查是否过期
  function checkExpired(text) {
    return EXPIRED_KEYWORDS.some(keyword => text.includes(keyword));
  }
  
  // 提取剩余天数
  function extractDays(text) {
    if (checkExpired(text)) return null;
    if (text.match(/剩余天数:\s*永久/i)) return Infinity;
    
    const match = text.match(/剩余天数:\s*(\d+)/);
    return match ? parseInt(match[1]) : null;
  }
  
  // 计算剩余价值（增加季付和半年付逻辑）
  function calculateRemaining(price, days, period) {
    let daily;
    switch (period) {
      case 'three-year': daily = price / 1095; break;
      case 'two-year': daily = price / 730; break;
      case 'year': daily = price / 365; break;
      case 'half-year': daily = price / 182.5; break;
      case 'quarter': daily = price / 90; break;
      default: daily = price / 30; // month
    }
    return daily * days;
  }
  
  // 获取样式类名
  function getValueStyle(remaining, original) {
    if (remaining === 0) return 'expired';
    
    const ratio = (remaining / original) * 100;
    if (ratio > 75) return 'excellent';
    if (ratio > 50) return 'good';
    if (ratio > 25) return 'moderate';
    if (ratio > 10) return 'low';
    return 'very-low';
  }
  
  // 添加标签
  function addTag(card, display, tagStyle, details) {
    const tag = document.createElement('p');
    tag.className = `vps-value-tag ${tagStyle}`;
    tag.title = generateTooltip(details);
    tag.textContent = `${CONFIG.tagText}${display}`;
    
    let container = findTagContainer(card);
    if (!container) return;
    
    if (CONFIG.tagPosition === 'first') {
      container.prepend(tag);
    } else {
      container.appendChild(tag);
    }
  }
  
  // 查找标签容器
  function findTagContainer(card) {
    // [FIX] 修正 CSS 选择器转义：mt-0.5 中的 . 需要转义为 \.
    // 在 JS 中 \. 写成 \\.（JS 转义 + CSS 转义）
    let container = card.querySelector('section.flex.gap-1.items-center.flex-wrap.mt-0\\.5');
    if (!container) {
      // 备选方案：按 class 组合查找
      const sections = card.querySelectorAll('section');
      for (const sec of sections) {
        const cls = sec.className;
        if (cls.includes('flex') && cls.includes('gap-1') && cls.includes('items-center') && cls.includes('flex-wrap')) {
          container = sec;
          break;
        }
      }
    }
    if (!container) {
      // 最终兜底：取卡片最后一个 section
      const sections = card.querySelectorAll('section');
      if (sections.length > 0) container = sections[sections.length - 1];
    }
    return container;
  }
  
  // 生成工具提示（适配新的周期显示）
  function generateTooltip(details) {
    let periodText = '月';
    let divisor = 30;

    if (details.period === 'three-year') { periodText = '三年'; divisor = 1095; }
    else if (details.period === 'two-year') { periodText = '两年'; divisor = 730; }
    else if (details.period === 'year') { periodText = '年'; divisor = 365; }
    else if (details.period === 'half-year') { periodText = '半年'; divisor = 182.5; }
    else if (details.period === 'quarter') { periodText = '季'; divisor = 90; }

    if (details.expired) {
      return `已过期VPS\n原价: ${details.symbol}${details.value}/${periodText}`;
    }
    
    const daily = details.value / divisor;
    const ratio = ((details.remaining / details.value) * 100).toFixed(1);
    
    return `原价: ${details.symbol}${details.value}/${periodText}\n` +
           `剩余天数: ${details.days}天\n` +
           `每日成本: ${details.symbol}${daily.toFixed(2)}/天\n` +
           `剩余价值占比: ${ratio}%`;
  }
  
  // 初始化函数
  function init() {
    processVPS();
    setTimeout(processVPS, 1000);
    setupMutationObserver();
    setInterval(processVPS, 30000);
  }
  
  // 设置MutationObserver
  function setupMutationObserver() {
    if (typeof MutationObserver !== 'undefined') {
      const observer = new MutationObserver((mutations) => {
        const hasVPSChanges = mutations.some(mutation => {
          if (mutation.type === 'childList') {
            for (const node of mutation.addedNodes) {
              if (node.nodeType === 1 && (node.classList?.contains('rounded-lg') || node.querySelector?.('.rounded-lg.bg-card'))) return true;
            }
            for (const node of mutation.removedNodes) {
              if (node.nodeType === 1 && node.classList?.contains('vps-value-tag')) return true;
            }
          }
          if (mutation.type === 'attributes' && mutation.attributeName === 'class' && mutation.target.classList?.contains('rounded-lg')) return true;
          return false;
        });
        
        if (hasVPSChanges) setTimeout(processVPS, 300);
      });
      
      observer.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] });
      window._vpsObserver = observer;
    }
  }
  
  // 全局API
  window.VPSRemainingValue = {
    recalculate: processVPS,
    setCurrency: function(symbol) { CONFIG.currency = symbol || '$'; processVPS(); return this; },
    setTagText: function(text) { CONFIG.tagText = text; processVPS(); return this; },
    setTagPosition: function(pos) { if (pos === 'first' || pos === 'last') { CONFIG.tagPosition = pos; processVPS(); } return this; },
    getConfig: function() { return { ...CONFIG }; },
    addExpiredKeyword: function(keyword) { if (!EXPIRED_KEYWORDS.includes(keyword)) EXPIRED_KEYWORDS.push(keyword); return this; },
    destroy: function() {
      if (window._vpsObserver) { window._vpsObserver.disconnect(); delete window._vpsObserver; }
      document.querySelectorAll('.vps-value-tag').forEach(tag => tag.remove());
      if (style.parentNode) style.parentNode.removeChild(style);
    }
  };
  
  window.recalculateVPSValues = processVPS;
  window.setCurrency = symbol => VPSRemainingValue.setCurrency(symbol);
  window.setTagText = text => VPSRemainingValue.setTagText(text);
  window.setTagPosition = pos => VPSRemainingValue.setTagPosition(pos);
  
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
  
})();
