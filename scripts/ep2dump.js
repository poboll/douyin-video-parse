'use strict';
// ============================================================
// ep2dump.js — 抖音精选(AwemeJX) 付费剧集 DRM dump agent
// 目标类: MediaDecrypter (AwemeJXCore.framework)
// 宿主App: com.ss.iphone.yumme.video (抖音精选 40.7.0)
//
// 用法:
//   frida -U -n AwemeJX -l ep2dump.js
// 模式(由 Mac 端 driver 切换):
//   recon = 只记录每次调用的 类/方法/各NSData参数的长度+前96字节
//   dump  = recon + 把完整数据写到 iPad 磁盘(Documents/ep2dump/)
//
// 设计: 只 hook 确认存在的选择器; 所有内存访问都在 try 里,
//       任何失败只跳过该次调用, 绝不影响 App 播放。
// ============================================================

var MODE = 'recon';              // 'recon' | 'dump'
var MAX_KEEP = 96;               // recon 模式每个 NSData 保留的字节数
var DUMP_DIR = '/var/mobile/Containers/Data/Application/'; // 占位, 运行时用 NSHomeDirectory

function log(s) { console.log('[ep2dump] ' + s); }

// ---------- iPad 端落盘(frida 16 File API, 失败则回退 send) ----------
var _fileHandle = null;
function deviceWrite(tag, bytes) {
  try {
    if (MODE !== 'dump') return false;
    if (typeof File === 'undefined') return false;
    if (_fileHandle === null) {
      // 优先 App 自己的 Documents(可用 WebDAV/Filza 直接拖走)
      var home = ObjC.classes.NSString
        .stringWithString_('~/Documents/ep2dump')
        .stringByExpandingTildeInPath().UTF8String();
      try {
        var fm = ObjC.classes.NSFileManager.defaultManager();
        fm.createDirectoryAtPath_withIntermediateDirectories_attributes_error_(
          ObjC.classes.NSString.stringWithString_(home), true, null, null);
      } catch (e) {}
      _fileHandle = new File(home + '/blocks.bin', 'wb');
    }
    _fileHandle.write(bytes);
    return true;
  } catch (e) { return false; }
}

// ---------- 安全地把一个参数指针当 NSData 读 ----------
function readNSData(ptr) {
  try {
    if (ptr.isNull()) return null;
    var low = ptr.mod(8);                 // 对象指针至少 8 字节对齐
    if (!low.isNull()) return null;
    var obj = new ObjC.Object(ptr);       // 不解引用
    var cn = obj.$className;              // 非法指针会抛可捕获异常
    if (cn !== '__NSCFData' && cn !== 'NSData' &&
        cn !== '__NSConcreteMutableData' && cn !== '_NSZeroData' &&
        cn !== 'NSMutableData' && cn !== '__NSCFString' && cn !== 'NSString') return null;
    var len;
    if (cn === '__NSCFString' || cn === 'NSString') {
      len = obj.lengthOfBytesUsingEncoding_(4).valueOf(); // UTF-8
      if (len <= 0) return null;
      var u8 = obj.UTF8String();
      return { cls: cn, len: len, str: Memory.readUtf8String(u8), data: null };
    }
    len = obj.length().valueOf();
    if (len <= 0 || len > 400 * 1024 * 1024) return null;
    var b = obj.bytes();
    return { cls: cn, len: len, data: Memory.readByteArray(b, len), str: null };
  } catch (e) { return null; }
}

function hexHead(u8, n) {
  var out = [];
  for (var i = 0; i < n && i < u8.length; i++) out.push(('0' + u8[i].toString(16)).slice(-2));
  return out.join('');
}

// ---------- hook 一个实例方法 ----------
var hooked = [];
var callCount = 0;

function hookInstanceMethod(className, sel) {
  try {
    var cls = ObjC.classes[className];
    if (!cls) return false;
    var m = cls['- ' + sel];
    if (!m) return false;
    var imp = m.implementation;
    Interceptor.attach(imp, {
      onEnter: function (args) {
        callCount++;
        var info = { cls: className, sel: sel, n: callCount };
        // 语义化参数位: 各选择器里 NSData 的常见位置
        var idxs = ARG_SPEC[sel] || [];
        var argInfos = [];
        for (var k = 0; k < idxs.length; k++) {
          var r = readNSData(args[idxs[k]]);
          if (r) argInfos.push({ i: idxs[k], cls: r.cls, len: r.len,
                                 head: r.data ? hexHead(new Uint8Array(r.data), MAX_KEEP) : (r.str ? r.str.slice(0, 120) : '') });
          else argInfos.push({ i: idxs[k], cls: '?', len: -1, head: '' });
        }
        // 返回值也抓(解密方法的明文/密钥 getter)
        this._argInfos = argInfos;
        this._info = info;
        send({ kind: 'meta', cls: className, sel: sel, n: callCount, args: argInfos });
        // dump 模式: 参数全量落盘
        if (MODE === 'dump') {
          for (var j = 0; j < idxs.length; j++) {
            var rr = readNSData(args[idxs[j]]);
            if (rr && rr.data && rr.len > 1024) {
              if (!deviceWrite(className + '__' + sel + '__a' + idxs[j] + '__', rr.data))
                send({ kind: 'data', tag: className + '__' + sel + '__a' + idxs[j] }, rr.data);
            }
          }
        }
      },
      onLeave: function (retval) {
        var r = readNSData(retval);
        if (r && (r.len > 0)) {
          var head = r.data ? hexHead(new Uint8Array(r.data), MAX_KEEP) : (r.str ? r.str.slice(0, 120) : '');
          send({ kind: 'ret', cls: this._info.cls, sel: this._info.sel, n: this._info.n,
                 cls_r: r.cls, len: r.len, head: head });
          if (MODE === 'dump' && r.data && r.len > 1024) {
            if (!deviceWrite(this._info.cls + '__' + this._info.sel + '__ret__', r.data))
              send({ kind: 'data', tag: this._info.cls + '__' + this._info.sel + '__ret' }, r.data);
          }
        }
      }
    });
    hooked.push(className + ' ' + sel);
    return true;
  } catch (e) {
    log('hook fail ' + className + ' ' + sel + ' : ' + e);
    return false;
  }
}

// 各选择器里 NSData 参数的常见索引(args[0]=self, args[1]=_cmd)
var ARG_SPEC = {
  'decryptBlock:':                              [2],
  'aesDecryptCacheData:withKey:error:cost:':    [2, 3],
  'aesDecryptwithData:KeyData:keySize:ivData:': [2, 3, 5],
  'aesDecryptwithKey:keySize:iv:':              [2, 4],
  'aesDecryptwithKeyData:keySize:ivData:':      [2, 3, 5],
  'AESDecryptData:keyData:ivData:':             [2, 3, 4],
  'AESDecryptString:keyData:ivData:':           [2, 3, 4],
  'AESDecryptString:keyString:ivString:':       [2, 3],
  'aesGCMDecryptCipher:tag:key:iv:':            [2, 3, 4, 5],
  'buildEncryptedDecryptionKey:':               [2],
  'decryptVideoFile:':                          [2],
  'decryptVideoFileAtPath:':                    [2],
  'aesDecryptString:withKey:':                  [2, 3],
};

// MediaDecrypter 相关类 + 通用 AES 类都扫一遍
var CLASS_CANDIDATES = ['MediaDecrypter'];

function installHooks() {
  // 1) 静态候选类
  for (var i = 0; i < CLASS_CANDIDATES.length; i++) {
    var cn = CLASS_CANDIDATES[i];
    if (!ObjC.classes[cn]) { log('class not loaded yet: ' + cn); continue; }
    for (var sel in ARG_SPEC) hookInstanceMethod(cn, sel);
  }
  // 2) 运行时枚举所有类, 凡实例方法命中 ARG_SPEC 的全部 hook(兜底)
  ObjC.enumerateLoadedClasses({
    onMatch: function (name) {
      try {
        var cls = ObjC.classes[name];
        for (var sel in ARG_SPEC) {
          if (cls['- ' + sel]) hookInstanceMethod(name, sel);
        }
      } catch (e) {}
    },
    onComplete: function () {
      log('hooks installed: ' + hooked.length);
      for (var i = 0; i < hooked.length; i++) log('  + ' + hooked[i]);
      send({ kind: 'ready', hooks: hooked });
    }
  });
}

// 类可能还没注册(等 AwemeJXCore 加载完), 轮询重试
var tries = 0;
function waitAndInstall() {
  tries++;
  if (ObjC.classes['MediaDecrypter'] || tries > 40) installHooks();
  else setTimeout(waitAndInstall, 500);
}

rpc.exports = {
  setmode: function (m) { MODE = m; log('MODE -> ' + m); return MODE; },
  status: function () { return { mode: MODE, calls: callCount, hooks: hooked }; },
  flush: function () { try { if (_fileHandle) { _fileHandle.flush && _fileHandle.flush(); } } catch (e) {} return 'ok'; }
};

log('agent loaded, waiting for MediaDecrypter...');
waitAndInstall();
