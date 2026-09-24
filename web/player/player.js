// Thin bridge between the Flutter app and the YouTube IFrame Player API.
// Web: the Flutter page embeds this page in a same-origin iframe and talks via postMessage.
// Native (Android/Windows): flutter_inappwebview calls window.ottPlayer.* directly and
// receives events through callHandler('ott', ...).
(function () {
  'use strict';

  var ID_RE = /^[A-Za-z0-9_-]{11}$/;
  var player = null;
  var ready = false;
  var pending = null;
  var tick = null;
  var parentOrigin = window.location.origin;
  var isNative = function () {
    return !!(window.flutter_inappwebview && window.flutter_inappwebview.callHandler);
  };

  function emit(type, data) {
    var msg = Object.assign({ source: 'ott-player', type: type }, data || {});
    if (isNative()) {
      window.flutter_inappwebview.callHandler('ott', msg);
    } else if (window.parent !== window) {
      window.parent.postMessage(msg, parentOrigin);
    }
  }

  function state() {
    if (!ready) return { t: 0, d: 0, playing: false };
    return {
      t: player.getCurrentTime() || 0,
      d: player.getDuration() || 0,
      playing: player.getPlayerState() === YT.PlayerState.PLAYING
    };
  }

  function startTicking() {
    if (tick) return;
    tick = setInterval(function () { emit('time', state()); }, 1000);
  }

  function stopTicking() {
    clearInterval(tick);
    tick = null;
  }

  var api = {
    load: function (id, start) {
      if (typeof id !== 'string' || !ID_RE.test(id)) return;
      start = Math.max(0, Number(start) || 0);
      if (!ready) { pending = { id: id, start: start }; return; }
      player.loadVideoById({ videoId: id, startSeconds: start });
      ensurePlaying();
    },
    seekBy: function (n) {
      if (!ready) return;
      n = Number(n);
      if (!isFinite(n)) return;
      var s = state();
      var target = Math.max(0, s.t + n);
      if (s.d && target >= s.d - 1) {
        target = Math.max(0, s.d - 1);
        emit('end-reached', {});
      }
      player.seekTo(target, true);
      player.playVideo(); // "forward" keeps playing
      emit('time', { t: target, d: s.d, playing: true });
    },
    pause: function () { if (ready) player.pauseVideo(); },
    play: function () { if (ready) player.playVideo(); },
    stop: function () {
      if (!ready) return;
      var s = state();
      player.pauseVideo();
      stopTicking();
      emit('stopped', s);
    },
    unmute: function () { if (ready) { player.unMute(); player.setVolume(100); } },
    getState: function () { return state(); }
  };
  window.ottPlayer = api;

  // Autoplay with sound can be blocked; fall back to muted playback and tell the app.
  function ensurePlaying() {
    setTimeout(function () {
      if (!ready) return;
      var st = player.getPlayerState();
      if (st === -1 || st === YT.PlayerState.CUED) { // still unstarted: autoplay was blocked
        player.mute();
        player.playVideo();
        emit('muted', {});
      }
    }, 1500);
  }

  window.addEventListener('message', function (e) {
    if (e.origin !== parentOrigin || e.source !== window.parent) return;
    var d = e.data;
    if (!d || d.target !== 'ott-player' || typeof d.cmd !== 'string') return;
    switch (d.cmd) {
      case 'load': api.load(d.id, d.start); break;
      case 'seekBy': api.seekBy(d.seconds); break;
      case 'pause': api.pause(); break;
      case 'play': api.play(); break;
      case 'stop': api.stop(); break;
      case 'unmute': api.unmute(); break;
      case 'state': emit('time', state()); break;
    }
  });

  var ERRORS = { 2: 'Invalid video', 5: 'Playback error', 100: 'Video not found',
                 101: 'Embedding disabled by the owner', 150: 'Embedding disabled by the owner' };

  window.onYouTubeIframeAPIReady = function () {
    player = new YT.Player('yt', {
      host: 'https://www.youtube-nocookie.com',
      width: '100%',
      height: '100%',
      playerVars: {
        autoplay: 1, playsinline: 1, rel: 0, modestbranding: 1, iv_load_policy: 3, disablekb: 1,
        origin: window.location.origin, enablejsapi: 1
      },
      events: {
        onReady: function () {
          ready = true;
          emit('ready', {});
          if (pending) { api.load(pending.id, pending.start); pending = null; }
        },
        onStateChange: function (e) {
          if (e.data === YT.PlayerState.PLAYING) startTicking();
          if (e.data === YT.PlayerState.ENDED) { stopTicking(); emit('ended', state()); }
          emit('state', state());
        },
        onError: function (e) { emit('error', { code: e.data, message: ERRORS[e.data] || 'Error' }); }
      }
    });
  };

  // Allow a direct URL for native WebViews: player.html#v=<id>&t=<start>
  var hash = new URLSearchParams(window.location.hash.slice(1));
  if (hash.get('v')) pending = { id: hash.get('v'), start: Number(hash.get('t')) || 0 };
  if (pending && !ID_RE.test(pending.id)) pending = null;
})();
