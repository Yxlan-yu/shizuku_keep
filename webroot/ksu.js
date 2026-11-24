/* KernelSU WebUI 桥接封装（Shizuku 常驻）
 * 官方接口: ksu.exec(command, JSON.stringify(options), callbackName)
 * 回调:     window[callbackName](errno, stdout, stderr)
 * 这里包成 Promise + 超时兜底，避免永久 pending。
 */
(function (global) {
  'use strict';

  var seq = 0;

  function ready() {
    return typeof global.ksu !== 'undefined' && global.ksu && typeof global.ksu.exec === 'function';
  }

  function exec(command, options, timeoutMs) {
    return new Promise(function (resolve) {
      if (!ready()) {
        resolve({ errno: -1, stdout: '', stderr: 'KernelSU 接口不可用，请在 KernelSU 管理器里打开本页面' });
        return;
      }

      var name = '__sk_cb_' + (++seq) + '_' + Date.now();
      var settled = false;
      var timer = setTimeout(function () {
        if (settled) return;
        settled = true;
        try { delete global[name]; } catch (e) { global[name] = undefined; }
        resolve({ errno: -2, stdout: '', stderr: '执行超时' });
      }, timeoutMs || 20000);

      global[name] = function (errno, stdout, stderr) {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        try { delete global[name]; } catch (e) { global[name] = undefined; }
        resolve({
          errno: typeof errno === 'number' ? errno : (parseInt(errno, 10) || 0),
          stdout: stdout == null ? '' : String(stdout),
          stderr: stderr == null ? '' : String(stderr)
        });
      };

      try {
        global.ksu.exec(command, JSON.stringify(options || {}), name);
      } catch (e) {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        try { delete global[name]; } catch (e2) { global[name] = undefined; }
        resolve({ errno: -3, stdout: '', stderr: String(e) });
      }
    });
  }

  function toast(msg) {
    try {
      if (typeof global.ksu !== 'undefined' && global.ksu && typeof global.ksu.toast === 'function') {
        global.ksu.toast(String(msg));
        return true;
      }
    } catch (e) { /* ignore */ }
    return false;
  }

  /* ------------------------------------------------------------------
   * 原生「包管理」接口（KernelSU Manager 3.x，Device Faker 等模块走的就是这条）
   *   ksu.pm() → { version(), listPackages(type), getPackagesInfo(json) }
   *   旧版是扁平的 ksu.listPackages(type) / ksu.getPackagesInfo(json)
   *   两端返回的都是 JSON 字符串，这里统一解析成数组；不支持时返回 null。
   * ------------------------------------------------------------------ */
  var pmObj = null, pmTried = false;

  function pmBridge() {
    if (pmTried) return pmObj;
    pmTried = true;
    var k = global.ksu;
    if (!k) return (pmObj = null);
    // 3.x：ksu.pm() 返回包管理对象
    try {
      if (typeof k.pm === 'function') {
        var o = k.pm();
        if (o && typeof o.listPackages === 'function') { pmObj = o; return pmObj; }
      }
    } catch (e) { /* 旧版管理器没有 pm() */ }
    // 少数分支把它做成属性而不是函数
    try {
      if (k.pm && typeof k.pm.listPackages === 'function') { pmObj = k.pm; return pmObj; }
    } catch (e) { /* ignore */ }
    // 更早的扁平接口
    try {
      if (typeof k.listPackages === 'function') { pmObj = k; return pmObj; }
    } catch (e) { /* ignore */ }
    return (pmObj = null);
  }

  function jsonArray(s) {
    if (s == null) return null;
    if (Object.prototype.toString.call(s) === '[object Array]') return s;
    if (typeof s !== 'string') return null;
    try {
      var a = JSON.parse(s);
      return Object.prototype.toString.call(a) === '[object Array]' ? a : null;
    } catch (e) { return null; }
  }

  // type: 'user' 只要用户应用 / 'system' 只要系统应用 / 'all' 全部
  function listPackages(type) {
    var b = pmBridge();
    if (!b) return null;
    try { return jsonArray(b.listPackages(type || 'user')); } catch (e) { return null; }
  }

  // 返回 [{packageName, appLabel, isSystem, uid, userId, versionName, error?}]
  function packagesInfo(pkgs) {
    var b = pmBridge();
    if (!b || typeof b.getPackagesInfo !== 'function') return null;
    try { return jsonArray(b.getPackagesInfo(JSON.stringify(pkgs))); } catch (e) { return null; }
  }

  function iconUrl(pkg) {
    return pmBridge() ? ('ksu://icon/' + pkg) : null;
  }

  global.SK = {
    ready: ready, exec: exec, toast: toast,
    hasPm: function () { return !!pmBridge(); },
    listPackages: listPackages,
    packagesInfo: packagesInfo,
    iconUrl: iconUrl
  };
})(window);
