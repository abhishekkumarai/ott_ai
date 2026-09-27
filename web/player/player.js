// Thin bridge between the Flutter app and video providers (YouTube & Vidy).
// Web: the Flutter page embeds this page in a same-origin iframe and talks via postMessage.
// Native (Android/Windows): flutter_inappwebview calls window.ottPlayer.* directly and
// receives events through callHandler('ott', ...).
(function () {
  'use strict';

  var YT_ID_RE = /^[A-Za-z0-9_-]{11}$/;
  var STREAM_ID_RE = /^([a-z0-9_-]+):(movie|tv|anime|video):([A-Za-z0-9_/-]+)$/;

  var player = null;
  var ready = false;
  var pending = null;
  var tick = null;
  var loop = null; // {a, b} seconds while an A-B loop is active
  var loopTimer = null;
  var captionsOn = false;
  var pendingOps = [];
  var desiredRate = null;
  function whenReady(fn) { if (ready) fn(); else pendingOps.push(fn); }

  var activeProvider = 'youtube'; // 'youtube' | 'vidy' | '2embed' | 'flixer' | etc.
  var streamIframe = null;
  var streamState = { t: 0, d: 0, playing: false };

  var QUALITY = { hd2160: '4K', hd1440: '1440p', hd1080: '1080p', hd720: '720p',
                  large: '480p', medium: '360p', small: '240p', tiny: '144p' };
  var parentOrigin = window.location.origin;
  var isNative = function () {
    return !!(window.flutter_inappwebview && window.flutter_inappwebview.callHandler);
  };

  function getStreamFrame() {
    if (!streamIframe) {
      streamIframe = document.getElementById('vidy') ||
                     document.getElementById('stream-frame') ||
                     document.querySelector('iframe');
    }
    return streamIframe;
  }
  var getVidyIframe = getStreamFrame;

  function buildProviderUrl(provider, mediaType, mediaId, start) {
    var parts = mediaId.split('/');
    var baseId = parts[0];
    switch (provider) {
      case 'vidy': {
        var url = 'https://vidy.st/' + mediaType + '/' + mediaId + '?color=FF5A3D';
        if (start > 0) url += '&progress=' + Math.round(start);
        url += '&autoplay=true&nextEpisode=true&episodeSelector=true';
        return url;
      }
      case '2embed': {
        if (mediaType === 'tv' && parts.length >= 3) {
          return 'https://www.2embed.cc/embedtv/' + baseId + '&s=' + parts[1] + '&e=' + parts[2];
        }
        return 'https://www.2embed.cc/embed/' + baseId;
      }
      case 'flixer': {
        return 'https://flixer.gd/watch/' + mediaType + '/' + mediaId;
      }
      case 'bcine': {
        return 'https://bcine.ru/embed/' + mediaType + '/' + mediaId;
      }
      case 'meowtv': {
        return 'https://meowtv.ru/embed/' + mediaType + '/' + mediaId;
      }
      case 'miruro': {
        var ep = parts[1] || '1';
        return 'https://miruro.com/watch?id=' + baseId + '&ep=' + ep;
      }
      case 'kaa': {
        return 'https://kaa.lt/watch/' + mediaId;
      }
      case 'tubi': {
        return 'https://tubitv.com/movies/' + mediaId;
      }
      default: {
        return 'https://vidy.st/' + mediaType + '/' + mediaId + '?color=FF5A3D&autoplay=true';
      }
    }
  }

  function emit(type, data) {
    var msg = Object.assign({ source: 'ott-player', type: type }, data || {});
    if (isNative()) {
      window.flutter_inappwebview.callHandler('ott', msg);
    } else if (window.parent !== window) {
      window.parent.postMessage(msg, parentOrigin);
    }
  }

  function state() {
    if (activeProvider !== 'youtube') {
      return {
        t: streamState.t || 0,
        d: streamState.d || 0,
        playing: !!streamState.playing,
        volume: 100,
        muted: false,
        rate: 1,
        quality: '1080p',
        captions: false,
        loopA: loop ? loop.a : null,
        loopB: loop ? loop.b : null
      };
    }
    if (!ready || !player) return { t: 0, d: 0, playing: false };
    return {
      t: (typeof player.getCurrentTime === 'function' ? player.getCurrentTime() : 0) || 0,
      d: (typeof player.getDuration === 'function' ? player.getDuration() : 0) || 0,
      playing: typeof player.getPlayerState === 'function' ? player.getPlayerState() === YT.PlayerState.PLAYING : false,
      volume: typeof player.getVolume === 'function' ? player.getVolume() : 100,
      muted: typeof player.isMuted === 'function' ? player.isMuted() : false,
      rate: typeof player.getPlaybackRate === 'function' ? player.getPlaybackRate() : 1,
      quality: typeof player.getPlaybackQuality === 'function' ? (QUALITY[player.getPlaybackQuality()] || '') : '',
      captions: captionsOn,
      loopA: loop ? loop.a : null,
      loopB: loop ? loop.b : null
    };
  }

  function clearLoop() {
    loop = null;
    clearInterval(loopTimer);
    loopTimer = null;
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
      if (typeof id !== 'string') return;
      start = Math.max(0, Number(start) || 0);

      var streamMatch = id.match(STREAM_ID_RE);
      if (streamMatch) {
        var provider = streamMatch[1];
        var mediaType = streamMatch[2]; // movie, tv, anime, video
        var mediaId = streamMatch[3];   // e.g. 315162, 1396/1/1, 21/1
        activeProvider = provider;
        clearLoop();
        stopTicking();
        if (ready && player && typeof player.pauseVideo === 'function') {
          try { player.pauseVideo(); } catch (e) {}
        }
        var ytEl = document.getElementById('yt');
        if (ytEl) ytEl.style.display = 'none';

        var vFrame = getStreamFrame();
        if (vFrame) {
          vFrame.style.display = 'block';
          var url = buildProviderUrl(provider, mediaType, mediaId, start);
          vFrame.src = url;
          streamState = { t: start, d: 0, playing: true };
          startTicking();
          emit('time', state());
          emit('state', state());
        }
        return;
      }

      if (!YT_ID_RE.test(id)) return;
      activeProvider = 'youtube';
      var vFrameOld = getStreamFrame();
      if (vFrameOld) {
        vFrameOld.style.display = 'none';
        vFrameOld.src = 'about:blank';
      }
      var ytElOld = document.getElementById('yt');
      if (ytElOld) ytElOld.style.display = 'block';

      if (!ready) { pending = { id: id, start: start }; return; }
      clearLoop();
      player.loadVideoById({ videoId: id, startSeconds: start });
      ensurePlaying();
    },
    seekBy: function (n) {
      n = Number(n);
      if (!isFinite(n)) return;
      var s = state();
      var target = Math.max(0, s.t + n);
      if (activeProvider !== 'youtube') {
        api.seekTo(target);
        return;
      }
      if (!ready) return;
      if (s.d && target >= s.d - 1) {
        target = Math.max(0, s.d - 1);
        emit('end-reached', {});
      }
      player.seekTo(target, true);
      player.playVideo(); // "forward" keeps playing
      emit('time', { t: target, d: s.d, playing: true });
    },
    pause: function () {
      if (activeProvider !== 'youtube') {
        streamState.playing = false;
        var vf = getStreamFrame();
        if (vf && vf.contentWindow) {
          try { vf.contentWindow.postMessage(JSON.stringify({ event: 'pause' }), '*'); } catch (e) {}
        }
        emit('state', state());
        return;
      }
      if (ready && player) player.pauseVideo();
    },
    play: function () {
      if (activeProvider !== 'youtube') {
        streamState.playing = true;
        var vf = getStreamFrame();
        if (vf && vf.contentWindow) {
          try { vf.contentWindow.postMessage(JSON.stringify({ event: 'play' }), '*'); } catch (e) {}
        }
        emit('state', state());
        return;
      }
      if (ready && player) player.playVideo();
    },
    stop: function () {
      clearLoop();
      stopTicking();
      if (activeProvider !== 'youtube') {
        var s = state();
        streamState.playing = false;
        var vf = getStreamFrame();
        if (vf) {
          vf.style.display = 'none';
          vf.src = 'about:blank';
        }
        var ytEl = document.getElementById('yt');
        if (ytEl) ytEl.style.display = 'block';
        emit('stopped', s);
        return;
      }
      if (!ready || !player) return;
      var sYt = state();
      player.pauseVideo();
      emit('stopped', sYt);
    },
    unmute: function () {
      if (activeProvider !== 'youtube') return;
      whenReady(function () {
        player.unMute();
        if (player.getVolume() === 0) player.setVolume(100);
        emit('time', state());
      });
    },
    mute: function () {
      if (activeProvider !== 'youtube') return;
      whenReady(function () { player.mute(); emit('time', state()); });
    },
    seekTo: function (t) {
      t = Number(t);
      if (!isFinite(t)) return;
      if (activeProvider !== 'youtube') {
        streamState.t = t;
        var vf = getStreamFrame();
        if (vf && vf.contentWindow) {
          try { vf.contentWindow.postMessage(JSON.stringify({ event: 'seek', currentTime: t }), '*'); } catch (e) {}
        }
        emit('time', { t: t, d: streamState.d, playing: streamState.playing });
        return;
      }
      if (!ready || !player) return;
      var d = player.getDuration() || 0;
      t = Math.max(0, d ? Math.min(t, d - 1) : t);
      player.seekTo(t, true);
      player.playVideo();
      emit('time', { t: t, d: d, playing: true });
    },
    setVolume: function (v) {
      if (activeProvider !== 'youtube') return;
      v = Math.max(0, Math.min(100, Math.round(Number(v) || 0)));
      whenReady(function () {
        player.setVolume(v);
        if (v > 0 && player.isMuted()) player.unMute();
        emit('time', state());
      });
    },
    setRate: function (r) {
      if (activeProvider !== 'youtube') return;
      r = Number(r);
      if ([0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2].indexOf(r) < 0) return;
      desiredRate = r;
      whenReady(function () { player.setPlaybackRate(r); emit('time', state()); });
    },
    captions: function (on) {
      if (activeProvider !== 'youtube') return;
      if (!ready) { whenReady(function () { api.captions(on); }); return; }
      captionsOn = !!on;
      try {
        if (captionsOn) player.loadModule('captions'); else player.unloadModule('captions');
      } catch (e) { captionsOn = false; }
      emit('time', state());
    },
    loop: function (a, b) {
      a = Number(a); b = Number(b);
      if (!isFinite(a) || !isFinite(b) || b - a < 1) return;
      clearLoop();
      loop = { a: Math.max(0, a), b: b };
      loopTimer = setInterval(function () {
        if (!loop) return;
        var s = state();
        if (s.t >= loop.b || s.t < loop.a - 1) api.seekTo(loop.a);
      }, 250);
      var cur = state();
      if (cur.t < loop.a || cur.t >= loop.b) api.seekTo(loop.a);
      api.play();
      emit('time', state());
    },
    unloop: function () { clearLoop(); emit('time', state()); },
    getState: function () { return state(); }
  };
  window.ottPlayer = api;

  // Autoplay with sound can be blocked; fall back to muted playback and tell the app.
  function ensurePlaying() {
    setTimeout(function () {
      if (!ready || !player) return;
      var st = player.getPlayerState();
      if (st === -1 || st === YT.PlayerState.CUED) { // still unstarted: autoplay was blocked
        player.mute();
        player.playVideo();
        emit('muted', {});
      }
    }, 1500);
  }

  // Handle incoming messages from both Flutter parent window and stream iframe.
  window.addEventListener('message', function (e) {
    var vf = getStreamFrame();
    if (vf && e.source === vf.contentWindow) {
      var payload = e.data;
      if (typeof payload === 'string') {
        try { payload = JSON.parse(payload); } catch (err) { return; }
      }
      if (!payload || typeof payload !== 'object') return;
      if (payload.event === 'timeupdate') {
        if (typeof payload.currentTime === 'number') streamState.t = payload.currentTime;
        if (typeof payload.duration === 'number') streamState.d = payload.duration;
        streamState.playing = true;
        emit('time', state());
      } else if (payload.event === 'play') {
        streamState.playing = true;
        emit('state', state());
      } else if (payload.event === 'pause') {
        streamState.playing = false;
        emit('state', state());
      } else if (payload.event === 'ended') {
        streamState.playing = false;
        emit('ended', state());
      }
      return;
    }

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
      case 'mute': api.mute(); break;
      case 'seekTo': api.seekTo(d.seconds); break;
      case 'setVolume': api.setVolume(d.value); break;
      case 'setRate': api.setRate(d.value); break;
      case 'captions': api.captions(d.value === 1); break;
      case 'loop': api.loop(d.start, d.end); break;
      case 'unloop': api.unloop(); break;
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
          var ops = pendingOps; pendingOps = [];
          ops.forEach(function (fn) { fn(); });
        },
        onStateChange: function (e) {
          if (activeProvider !== 'youtube') return;
          if (e.data === YT.PlayerState.PLAYING) {
            startTicking();
            if (desiredRate && player.getPlaybackRate() !== desiredRate) player.setPlaybackRate(desiredRate);
          }
          if (e.data === YT.PlayerState.ENDED) {
            if (loop) { player.seekTo(loop.a, true); player.playVideo(); return; }
            stopTicking();
            emit('ended', state());
          }
          emit('state', state());
        },
        onError: function (e) {
          if (activeProvider !== 'youtube') return;
          emit('error', { code: e.data, message: ERRORS[e.data] || 'Error' });
        }
      }
    });
  };

  // Allow a direct URL for native WebViews: player.html#v=<id>&t=<start>
  var hash = new URLSearchParams(window.location.hash.slice(1));
  var hashV = hash.get('v');
  if (hashV && (YT_ID_RE.test(hashV) || STREAM_ID_RE.test(hashV))) {
    pending = { id: hashV, start: Number(hash.get('t')) || 0 };
  }
})();
