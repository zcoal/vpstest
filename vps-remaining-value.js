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
    document.querySelectorAll('.rounded-lg.border.bg-card').forEach(card => {
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
        const style = getValueStyle(remaining, price.value);
        
        addTag(card, display, style, { ...price, days, remaining });
        
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
  
  // 提取价格信息
  function extractPrice(text) {
    // 一次性付费（支持HK$等货币符号）
    const oneTimeMatch = text.match(/价格:\s*((?:HK\$|US\$|C\$|A\$|€|£|¥|￥|\$)?\s*[\d.,]+)\/-/);
    if (oneTimeMatch) return parsePrice(oneTimeMatch[1], true);
    
    // 免费
    if (text.match(/价格:\s*(免费|Free|0)/i)) return { free: true };
    
    // 正常价格（支持多种货币符号）
    const normalMatch = text.match(/价格:\s*((?:HK\$|US\$|C\$|A\$|€|£|¥|￥|\$)?\s*[\d.,]+)(?:\/(月|年))?/);
    if (normalMatch) return parsePrice(normalMatch[1], false, normalMatch[2]);
    
    return null;
  }
  
  // 解析价格
  function parsePrice(str, oneTime = false, period = '月') {
    // 提取货币符号
    let symbol = CONFIG.currency;
    let valueStr = str;
    
    // 检查是否包含已知货币符号
    for (const currency of CURRENCY_SYMBOLS) {
      if (str.startsWith(currency)) {
        symbol = currency;
        valueStr = str.substring(currency.length).trim();
        break;
      }
    }
    
    // 清理数字字符串（移除逗号）
    const cleanValueStr = valueStr.replace(/,/g, '');
    const value = parseFloat(cleanValueStr);
    
    return {
      value, 
      symbol,
      free: false,
      oneTime,
      period: period === '年' ? 'year' : 'month'
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
  
  // 计算剩余价值
  function calculateRemaining(price, days, period) {
    const daily = period === 'year' ? price / 365 : price / 30;
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
  function addTag(card, display, style, details) {
    const tag = document.createElement('p');
    tag.className = `vps-value-tag ${style}`;
    tag.title = generateTooltip(details);
    tag.textContent = `${CONFIG.tagText}${display}`;
    
    // 寻找标签容器
    let container = findTagContainer(card);
    
    if (!container) {
      console.warn('未找到标签容器:', card);
      return;
    }
    
    // 根据配置添加标签
    if (CONFIG.tagPosition === 'first') {
      container.prepend(tag);
    } else {
      container.appendChild(tag);
    }
  }
  
  // 查找标签容器
  function findTagContainer(card) {
    // 尝试标准选择器
    let container = card.querySelector('section.flex.gap-1.items-center.flex-wrap.mt-0\\.5');
    
    if (!container) {
      // 尝试在卡片内查找任何flex容器
      const sections = card.querySelectorAll('section.flex.items-center.gap-1');
      if (sections.length > 0) {
        container = sections[0];
      }
    }
    
    // 如果还是没找到，尝试最后一个section元素
    if (!container) {
      const sections = card.querySelectorAll('section');
      if (sections.length > 0) {
        container = sections[sections.length - 1];
      }
    }
    
    return container;
  }
  
  // 生成工具提示
  function generateTooltip(details) {
    if (details.expired) {
      return `已过期VPS\n原价: ${details.symbol}${details.value}/${details.period === 'year' ? '年' : '月'}`;
    }
    
    const period = details.period === 'year' ? '年' : '月';
    const daily = details.period === 'year' ? details.value / 365 : details.value / 30;
    const ratio = ((details.remaining / details.value) * 100).toFixed(1);
    
    return `原价: ${details.symbol}${details.value}/${period}\n` +
           `剩余天数: ${details.days}天\n` +
           `每日成本: ${details.symbol}${daily.toFixed(2)}/天\n` +
           `剩余价值占比: ${ratio}%`;
  }
  
  // 初始化函数
  function init() {
    // 立即执行一次
    processVPS();
    
    // 延迟执行以确保页面加载完成
    setTimeout(processVPS, 1000);
    
    // 设置观察器
    setupMutationObserver();
    
    // 定期检查（每30秒）
    setInterval(processVPS, 30000);
    
    console.log('VPS剩余价值计算器已加载');
  }
  
  // 设置MutationObserver
  function setupMutationObserver() {
    if (typeof MutationObserver !== 'undefined') {
      const observer = new MutationObserver((mutations) => {
        // 检查是否有VPS卡片相关的变更
        const hasVPSChanges = mutations.some(mutation => {
          // 检查是否有新增或移除的节点
          if (mutation.type === 'childList') {
            // 检查新增的节点中是否有VPS卡片
            for (const node of mutation.addedNodes) {
              if (node.nodeType === 1 && 
                  (node.classList?.contains('rounded-lg') || 
                   node.querySelector?.('.rounded-lg.border.bg-card'))) {
                return true;
              }
            }
            // 检查移除的节点中是否有我们的标签
            for (const node of mutation.removedNodes) {
              if (node.nodeType === 1 && node.classList?.contains('vps-value-tag')) {
                return true;
              }
            }
          }
          // 检查class属性的变化（状态变化）
          if (mutation.type === 'attributes' && 
              mutation.attributeName === 'class' &&
              mutation.target.classList?.contains('rounded-lg')) {
            return true;
          }
          return false;
        });
        
        if (hasVPSChanges) {
          setTimeout(processVPS, 300);
        }
      });
      
      observer.observe(document.body, { 
        childList: true, 
        subtree: true,
        attributes: true,
        attributeFilter: ['class']
      });
      
      // 保存观察器以便后续使用
      window._vpsObserver = observer;
    }
  }
  
  // 全局API
  window.VPSRemainingValue = {
    // 重新计算所有VPS
    recalculate: processVPS,
    
    // 设置货币符号
    setCurrency: function(symbol) {
      CONFIG.currency = symbol || '$';
      processVPS();
      return this;
    },
    
    // 设置标签文本
    setTagText: function(text) {
      CONFIG.tagText = text;
      processVPS();
      return this;
    },
    
    // 设置标签位置
    setTagPosition: function(pos) {
      if (pos === 'first' || pos === 'last') {
        CONFIG.tagPosition = pos;
        processVPS();
      }
      return this;
    },
    
    // 获取当前配置
    getConfig: function() {
      return { ...CONFIG };
    },
    
    // 添加过期关键词
    addExpiredKeyword: function(keyword) {
      if (!EXPIRED_KEYWORDS.includes(keyword)) {
        EXPIRED_KEYWORDS.push(keyword);
      }
      return this;
    },
    
    // 移除观察器（清理）
    destroy: function() {
      if (window._vpsObserver) {
        window._vpsObserver.disconnect();
        delete window._vpsObserver;
      }
      
      // 移除所有标签
      document.querySelectorAll('.vps-value-tag').forEach(tag => tag.remove());
      
      // 移除样式
      if (style.parentNode) {
        style.parentNode.removeChild(style);
      }
    }
  };
  
  // 兼容旧的全局函数
  window.recalculateVPSValues = processVPS;
  window.setCurrency = symbol => VPSRemainingValue.setCurrency(symbol);
  window.setTagText = text => VPSRemainingValue.setTagText(text);
  window.setTagPosition = pos => VPSRemainingValue.setTagPosition(pos);
  
  // 自动初始化
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
  
})();