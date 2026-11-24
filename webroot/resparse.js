/* =====================================================================
 *  resparse.js —— 纯前端解析 Android 二进制资源
 *    1) AXML  (AndroidManifest.xml) → application 的 label / icon 资源 ID
 *    2) ARSC  (resources.arsc)      → 资源 ID 对应的字符串
 *  只依赖 Uint8Array / TextDecoder，KernelSU WebUI 的 WebView 里可直接跑。
 * ===================================================================== */
var ResParse = (function () {
  'use strict';

  var utf8 = new TextDecoder('utf-8');
  var utf16 = new TextDecoder('utf-16le');

  function u16(b, o) { return b[o] | (b[o + 1] << 8); }
  function u32(b, o) {
    return (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0;
  }

  /* ---------------- 字符串池（惰性解码） ---------------- */
  function Pool(buf, off) {
    var type = u16(buf, off);
    if (type !== 0x0001) throw new Error('not a string pool: 0x' + type.toString(16));
    this.buf = buf;
    this.off = off;
    this.hsize = u16(buf, off + 2);
    this.count = u32(buf, off + 8);
    this.flags = u32(buf, off + 16);
    this.utf8 = !!(this.flags & 0x100);
    this.base = off + u32(buf, off + 20);
    this.cache = {};
    this.size = u32(buf, off + 4);
  }

  Pool.prototype.get = function (i) {
    if (i < 0 || i >= this.count) return '';
    var got = this.cache[i];
    if (got !== undefined) return got;
    var b = this.buf;
    var p = this.base + u32(b, this.off + this.hsize + i * 4);
    var s = '';
    try {
      if (this.utf8) {
        var l = b[p];
        p += (l & 0x80) ? 2 : 1;
        var bl = b[p];
        if (bl & 0x80) { bl = ((bl & 0x7f) << 8) | b[p + 1]; p += 2; } else { p += 1; }
        s = utf8.decode(b.subarray(p, p + bl));
      } else {
        var n = u16(b, p); p += 2;
        if (n & 0x8000) { n = ((n & 0x7fff) << 16) | u16(b, p); p += 2; }
        s = utf16.decode(b.subarray(p, p + n * 2));
      }
    } catch (e) { s = ''; }
    this.cache[i] = s;
    return s;
  };

  /* ---------------- AXML：取 application 的 label / icon ---------------- */
  function parseManifest(buf) {
    var out = { label: 0, icon: 0, roundIcon: 0, labelText: null };
    var pool = null;
    var off = 8;
    var n = buf.length;
    while (off + 8 <= n) {
      var type = u16(buf, off), hsize = u16(buf, off + 2), size = u32(buf, off + 4);
      if (size < 8 || off + size > n) break;
      if (type === 0x0001) {
        pool = new Pool(buf, off);
      } else if (type === 0x0102 && pool) {          // START_ELEMENT
        var nameIdx = u32(buf, off + 20);
        var tag = pool.get(nameIdx);
        if (tag === 'application') {
          var astart = u16(buf, off + 24);
          var asize = u16(buf, off + 26);
          var acount = u16(buf, off + 28);
          for (var i = 0; i < acount; i++) {
            var a = off + 16 + astart + i * asize;
            var aname = pool.get(u32(buf, a + 4));
            var araw = u32(buf, a + 8);
            var vtype = buf[a + 15];
            var vdata = u32(buf, a + 16);
            if (aname === 'label') {
              if (vtype === 0x01) out.label = vdata;
              else if (vtype === 0x03) out.labelText = pool.get(vdata);
            } else if (aname === 'icon') {
              if (vtype === 0x01) out.icon = vdata;
            } else if (aname === 'roundIcon') {
              if (vtype === 0x01) out.roundIcon = vdata;
            }
          }
          if (out.label || out.labelText) break;
        }
      }
      off += size;
    }
    return out;
  }

  /* ---------------- ARSC：资源 ID → 字符串 ---------------- */  function Arsc(buf) {
    if (u16(buf, 0) !== 0x0002) throw new Error('not a resource table');
    this.buf = buf;
    var off = u16(buf, 2);
    this.gstr = new Pool(buf, off);
    off += u32(buf, off + 4);
    this.map = {};
    var n = buf.length;
    while (off + 8 <= n) {
      var type = u16(buf, off), hsize = u16(buf, off + 2), size = u32(buf, off + 4);
      if (size < 8 || off + size > n) break;
      if (type === 0x0200) this._pkg(off, hsize, size);
      off += size;
    }
  }

  Arsc.prototype._pkg = function (off, hsize, size) {
    var b = this.buf;
    var pid = u32(b, off + 8);
    var p = off + hsize;
    var end = off + size;
    while (p + 8 <= end) {
      var type = u16(b, p), h2 = u16(b, p + 2), c2 = u32(b, p + 4);
      if (c2 < 8 || p + c2 > end) break;
      if (type === 0x0201) {                         // TYPE
        var tid = b[p + 8];
        var ecount = u32(b, p + 12);
        var estart = u32(b, p + 16);
        var isDef = true;
        for (var k = p + 24; k < p + h2; k++) {       // 跳过 config.size 前 4 字节
          if (b[k] !== 0) { isDef = false; break; }
        }
        var ecOff = p + h2;
        for (var i = 0; i < ecount; i++) {
          var eo = u32(b, ecOff + i * 4);
          if (eo === 0xFFFFFFFF) continue;
          var ep = p + estart + eo;
          if (ep + 8 > b.length) continue;
          var esize = u16(b, ep), efl = u16(b, ep + 2);
          if (efl & 0x0001) continue;                 // complex entry
          var vp = ep + esize;
          if (vp + 8 > b.length) continue;
          var vt = b[vp + 3], vd = u32(b, vp + 4);
          var key = pid + ':' + tid + ':' + i;
          var arr = this.map[key];
          if (!arr) arr = this.map[key] = [];
          arr.push({ def: isDef, t: vt, d: vd });
        }
      }
      p += c2;
    }
  };

  /* 返回该资源 ID 的全部字符串值：[{def, s}] */
  Arsc.prototype.strings = function (resid) {
    if (!resid) return [];
    var pid = (resid >>> 24) & 0xff, tid = (resid >>> 16) & 0xff, eid = resid & 0xffff;
    var arr = this.map[pid + ':' + tid + ':' + eid];
    if (!arr) return [];
    var out = [];
    for (var i = 0; i < arr.length; i++) {
      if (arr[i].t !== 0x03) continue;
      out.push({ def: arr[i].def, s: this.gstr.get(arr[i].d) });
    }
    return out;
  };

  /* 取默认配置的字符串，没有默认就取第一个 */
  Arsc.prototype.get = function (resid) {
    var list = this.strings(resid);
    if (!list.length) return null;
    for (var i = 0; i < list.length; i++) if (list[i].def) return list[i].s;
    return list[0].s;
  };

  /* ---------------- 对外：从一对 buffer 得出名字和图标路径 ---------------- */
  var IMG = /\.(png|webp|jpg|jpeg)$/i;

  function resolve(manifestBuf, arscBuf) {
    var info = parseManifest(manifestBuf);
    var r = { label: info.labelText || null, icon: null, labelRes: info.label, iconRes: info.icon };
    if (!arscBuf) return r;
    var arsc = new Arsc(arscBuf);

    if (!r.label) {
      var l = arsc.get(info.label);
      if (l) r.label = l;
    }

    // 图标：同一资源 ID 往往有多个密度配置，优先真图片（xml 是自适应图标，跳过）
    var candidates = [];
    if (info.icon) candidates = candidates.concat(arsc.strings(info.icon));
    if (!candidates.length && info.roundIcon) candidates = arsc.strings(info.roundIcon);

    var defImg = null, anyImg = null, defAny = null;
    for (var i = 0; i < candidates.length; i++) {
      var s = candidates[i].s;
      if (!s) continue;
      if (IMG.test(s)) {
        if (candidates[i].def && !defImg) defImg = s;
        if (!anyImg) anyImg = s;
      } else if (candidates[i].def && !defAny) {
        defAny = s;
      }
    }
    r.icon = defImg || anyImg || null;
    r.iconXml = defImg || anyImg ? null : defAny;
    if (r.iconXml) r._arsc = arsc;      // 自适应图标：留着实例，供二次挖真位图
    return r;
  }

  /* ---------------- 自适应图标 XML：挖出 foreground 的真实位图 ---------------- */
  function parseAdaptive(buf) {
    var out = { foreground: 0, background: 0 };
    var pool = null, off = 8, n = buf.length;
    while (off + 8 <= n) {
      var type = u16(buf, off), size = u32(buf, off + 4);
      if (size < 8 || off + size > n) break;
      if (type === 0x0001) {
        pool = new Pool(buf, off);
      } else if (type === 0x0102 && pool) {
        var tag = pool.get(u32(buf, off + 20));
        if (tag === 'foreground' || tag === 'background') {
          var astart = u16(buf, off + 24), asize = u16(buf, off + 26), acount = u16(buf, off + 28);
          for (var i = 0; i < acount; i++) {
            var a = off + 16 + astart + i * asize;
            if (pool.get(u32(buf, a + 4)) === 'drawable' && buf[a + 15] === 0x01) {
              out[tag] = u32(buf, a + 16);
            }
          }
        }
      }
      off += size;
    }
    return out;
  }

  /* 从自适应图标的 XML 里找出真位图路径 */
  function iconFromAdaptive(arsc, xmlBuf) {
    if (!arsc) return null;
    var ref = parseAdaptive(xmlBuf);
    var tries = [ref.foreground, ref.background];
    for (var t = 0; t < tries.length; t++) {
      if (!tries[t]) continue;
      var list = arsc.strings(tries[t]);
      var any = null;
      for (var i = 0; i < list.length; i++) {
        if (!list[i].s) continue;
        if (IMG.test(list[i].s)) {
          if (list[i].def) return list[i].s;
          if (!any) any = list[i].s;
        }
      }
      if (any) return any;
    }
    return null;
  }

  return {
    resolve: resolve,
    parseManifest: parseManifest,
    parseAdaptive: parseAdaptive,
    iconFromAdaptive: iconFromAdaptive,
    Arsc: Arsc
  };
})();

if (typeof module !== 'undefined') module.exports = ResParse;
