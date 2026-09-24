// Catalog admin. The access token lives only in memory; the refresh token is an
// HttpOnly cookie the page cannot read. All text is written with textContent.
(function () {
  'use strict';

  var token = null;
  var page = { offset: 0, limit: 25, total: 0 };
  var $ = function (id) { return document.getElementById(id); };
  var ID_RE = /^[A-Za-z0-9_-]{11}$/;

  function show(view) {
    $('login-view').classList.toggle('hidden', view !== 'login');
    $('catalog-view').classList.toggle('hidden', view !== 'catalog');
    $('logout').classList.toggle('hidden', view !== 'catalog');
  }

  async function api(path, opts, retried) {
    opts = opts || {};
    var headers = { 'Content-Type': 'application/json' };
    if (token) headers.Authorization = 'Bearer ' + token;
    var res = await fetch('/api' + path, {
      method: opts.method || 'GET',
      headers: headers,
      body: opts.body ? JSON.stringify(opts.body) : undefined,
      credentials: 'same-origin'
    });
    if (res.status === 401 && !retried && path.indexOf('/auth/') !== 0) {
      if (await refresh()) return api(path, opts, true);
      show('login');
    }
    var data = res.status === 204 ? null : await res.json().catch(function () { return null; });
    if (!res.ok) {
      var detail = data && data.detail;
      if (Array.isArray(detail)) detail = detail.map(function (d) { return d.msg; }).join('; ');
      throw new Error(typeof detail === 'string' ? detail : 'Request failed (' + res.status + ')');
    }
    return data;
  }

  async function refresh() {
    try {
      var data = await api('/auth/refresh', { method: 'POST' }, true);
      return signedIn(data);
    } catch (e) {
      return false;
    }
  }

  function signedIn(data) {
    if (!data || !data.user || !data.user.is_admin) {
      token = null;
      return false;
    }
    token = data.access_token;
    $('who').textContent = data.user.email;
    return true;
  }

  function parseId(input) {
    input = input.trim();
    if (ID_RE.test(input)) return input;
    try {
      var u = new URL(input);
      var host = u.hostname.replace(/^www\.|^m\./, '');
      var id = null;
      if (host === 'youtu.be') id = u.pathname.slice(1);
      else if (host === 'youtube.com' || host === 'youtube-nocookie.com') {
        id = u.searchParams.get('v') || (u.pathname.match(/^\/(?:embed|shorts|live)\/([^/]+)/) || [])[1];
      }
      return id && ID_RE.test(id) ? id : null;
    } catch (e) {
      return null;
    }
  }

  function tags(str) {
    return str.split(',').map(function (t) { return t.trim(); })
      .filter(Boolean).slice(0, 15).map(function (t) { return t.slice(0, 60); });
  }

  function fmt(s) {
    var m = Math.floor(s / 60), r = s % 60;
    return m + ':' + (r < 10 ? '0' : '') + r;
  }

  function status(el, text, ok) {
    el.textContent = text;
    el.className = 'text-sm sm:col-span-4 ' + (ok ? 'text-muted-foreground' : 'text-destructive');
  }

  async function load() {
    var params = new URLSearchParams({
      q: $('q').value.trim(), source: $('source').value,
      offset: String(page.offset), limit: String(page.limit)
    });
    var data = await api('/admin/videos?' + params.toString());
    page.total = data.total;
    $('count').textContent = data.total + ' video' + (data.total === 1 ? '' : 's');
    $('prev').disabled = page.offset === 0;
    $('next').disabled = page.offset + page.limit >= data.total;
    var tbody = $('rows');
    tbody.replaceChildren();
    data.items.forEach(function (v) { tbody.appendChild(row(v)); });
  }

  function row(v) {
    var tr = $('row-tpl').content.firstElementChild.cloneNode(true);
    var f = function (name) { return tr.querySelector('[data-f="' + name + '"]'); };
    tr.querySelector('img').src = 'https://i.ytimg.com/vi/' + v.youtube_id + '/mqdefault.jpg';
    f('title').textContent = v.title;
    f('channel').textContent = v.channel + ' · ' + v.youtube_id;
    f('topic').value = v.topic;
    f('tags').value = v.tags.join(', ');
    f('dur').textContent = fmt(v.duration_s);
    f('source').textContent = v.source === 'curated' ? 'Curated' : 'Search';
    tr.querySelector('[data-a="save"]').addEventListener('click', async function (e) {
      var btn = e.currentTarget;
      btn.disabled = true;
      try {
        await api('/admin/videos/' + v.youtube_id, {
          method: 'PATCH', body: { topic: f('topic').value.trim(), tags: tags(f('tags').value) }
        });
        btn.textContent = 'Saved';
        setTimeout(function () { btn.textContent = 'Save'; }, 1200);
        await load();
      } catch (err) {
        btn.textContent = 'Error';
        btn.title = err.message;
      } finally {
        btn.disabled = false;
      }
    });
    tr.querySelector('[data-a="del"]').addEventListener('click', async function (e) {
      var btn = e.currentTarget;
      if (btn.dataset.confirm !== '1') {
        btn.dataset.confirm = '1';
        btn.textContent = 'Confirm';
        setTimeout(function () { btn.dataset.confirm = ''; btn.textContent = 'Delete'; }, 3000);
        return;
      }
      await api('/admin/videos/' + v.youtube_id, { method: 'DELETE' });
      await load();
    });
    return tr;
  }

  $('login-form').addEventListener('submit', async function (e) {
    e.preventDefault();
    var err = $('login-error');
    err.classList.add('hidden');
    try {
      var data = await api('/auth/login', {
        method: 'POST', body: { email: $('email').value.trim(), password: $('password').value }
      });
      $('password').value = '';
      if (!signedIn(data)) throw new Error('This account is not an admin.');
      show('catalog');
      await load();
    } catch (ex) {
      err.textContent = ex.message;
      err.classList.remove('hidden');
    }
  });

  $('add-form').addEventListener('submit', async function (e) {
    e.preventDefault();
    var msg = $('add-msg');
    var id = parseId($('add-id').value);
    var topic = $('add-topic').value.trim();
    if (!id) return status(msg, 'That is not a YouTube URL or 11-character video ID.', false);
    if (!topic) return status(msg, 'Topic is required.', false);
    status(msg, 'Adding…', true);
    try {
      var v = await api('/admin/videos', {
        method: 'POST', body: { youtube_id: id, topic: topic, tags: tags($('add-tags').value) }
      });
      status(msg, 'Added “' + v.title + '”.', true);
      $('add-form').reset();
      page.offset = 0;
      await load();
    } catch (ex) {
      status(msg, ex.message, false);
    }
  });

  var debounce;
  $('q').addEventListener('input', function () {
    clearTimeout(debounce);
    debounce = setTimeout(function () { page.offset = 0; load(); }, 250);
  });
  $('source').addEventListener('change', function () { page.offset = 0; load(); });
  $('prev').addEventListener('click', function () { page.offset = Math.max(0, page.offset - page.limit); load(); });
  $('next').addEventListener('click', function () { page.offset += page.limit; load(); });
  $('logout').addEventListener('click', async function () {
    await api('/auth/logout', { method: 'POST' }).catch(function () {});
    token = null;
    show('login');
  });

  refresh().then(function (ok) {
    if (ok) { show('catalog'); load(); } else { show('login'); }
  });
})();
