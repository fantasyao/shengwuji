/// 电脑访问服务的浏览器端管理页（单文件 SPA，GET / 直接返回）。
///
/// 无框架无构建： vanilla JS + 内联 CSS，与 App 同视觉语言（浅灰底 / 白卡片 /
/// 绿色主色 #2E9F5C，呼应悬浮窗胶囊配色）。功能：
/// - 日记列表：活跃 / 已归档两个分区，卡片含时间、时长、标注、内容
///   （`- [ ]` / `- [x]` 清单行渲染成勾选框）、录音播放器
/// - 复制：卡片一键复制全文 → 本机剪贴板（toast 反馈）
/// - 编辑：弹层 textarea → PUT /api/notes/{id}
/// - 删除：confirm → DELETE /api/notes/{id}（录音一并删，与手机端语义一致）
/// - 实时刷新：EventSource('/api/events') 收到 changed 即重拉列表；
///   SSE 断线自动重连（浏览器内建），另有手动刷新按钮兜底
/// - 录音 <audio preload="none">：点播放才拉流，100 条录音也不会全量下载
const String diaryWebPageHtml = r'''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>声物记 · 随手记</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC",
      "Microsoft YaHei", "Noto Sans CJK SC", sans-serif;
    background: #f2f4ef; color: #2b2f2a; padding-bottom: 60px;
  }
  header {
    position: sticky; top: 0; z-index: 10;
    background: rgba(245,246,243,.95); border-bottom: 1px solid #e3e6de;
    padding: 12px 20px; display: flex; align-items: center; gap: 12px;
  }
  header h1 { font-size: 17px; font-weight: 700; }
  header .sub { font-size: 12px; color: #8a9084; }
  .spacer { flex: 1; }
  .conn { display: flex; align-items: center; gap: 6px; font-size: 12px; color: #8a9084; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: #bbb; }
  .dot.live { background: #2E9F5C; }
  .dot.reconnecting { background: #e6a23c; }
  button.refresh {
    border: 1px solid #d7dbd0; background: #fff; border-radius: 8px;
    padding: 6px 12px; font-size: 13px; cursor: pointer; color: #444;
  }
  button.refresh:hover { border-color: #2E9F5C; color: #2E9F5C; }
  main { max-width: 760px; margin: 0 auto; padding: 16px 16px 0; }
  .section-title {
    font-size: 13px; color: #8a9084; margin: 18px 4px 10px;
    display: flex; align-items: center; gap: 8px;
  }
  .count { background: #e6e9e0; border-radius: 10px; padding: 1px 8px; font-size: 11px; }
  .card {
    background: #fff; border-radius: 14px; padding: 14px 16px; margin-bottom: 10px;
    border: 1px solid #eceee7; box-shadow: 0 1px 2px rgba(0,0,0,.03);
  }
  .card .meta {
    display: flex; align-items: center; gap: 8px; font-size: 12px;
    color: #9aa093; margin-bottom: 8px; flex-wrap: wrap;
  }
  .chip { background: #f0f2ea; border-radius: 6px; padding: 1px 7px; }
  .chip.tag-urgent { background: #fdecec; color: #c0392b; }
  .chip.tag-star { background: #fdf3d7; color: #a97b00; }
  .chip.tag-idea { background: #e7f0fd; color: #2563c4; }
  .content { font-size: 14.5px; line-height: 1.75; word-break: break-word; white-space: pre-wrap; }
  .checkline { display: flex; gap: 7px; align-items: baseline; }
  .checkline input { accent-color: #2E9F5C; position: relative; top: 2px; }
  .checkline.done { color: #a5ab9e; text-decoration: line-through; }
  audio { width: 100%; margin-top: 10px; height: 36px; }
  .actions { display: flex; gap: 8px; justify-content: flex-end; margin-top: 10px; }
  .actions button {
    border: 1px solid #d7dbd0; background: #fff; border-radius: 8px;
    padding: 4px 12px; font-size: 12.5px; cursor: pointer; color: #555;
  }
  .actions button.danger:hover { border-color: #c0392b; color: #c0392b; }
  .actions button.edit:hover, .actions button.copy:hover { border-color: #2E9F5C; color: #2E9F5C; }
  .empty { text-align: center; color: #a5ab9e; padding: 60px 0; font-size: 14px; }
  /* 编辑弹层 */
  #editMask {
    position: fixed; inset: 0; background: rgba(0,0,0,.45); z-index: 50;
    display: flex; align-items: center; justify-content: center; padding: 20px;
  }
  #editMask[hidden] { display: none; }
  .modal {
    background: #fff; border-radius: 16px; padding: 18px; width: 100%; max-width: 560px;
  }
  .modal h3 { font-size: 15px; margin-bottom: 12px; }
  .modal textarea {
    width: 100%; height: 220px; resize: vertical; border: 1px solid #d7dbd0;
    border-radius: 10px; padding: 10px 12px; font-size: 14px; line-height: 1.7;
    font-family: inherit; outline: none;
  }
  .modal textarea:focus { border-color: #2E9F5C; }
  .modal-actions { display: flex; justify-content: flex-end; gap: 10px; margin-top: 14px; }
  .modal-actions button {
    border-radius: 9px; padding: 7px 18px; font-size: 13.5px; cursor: pointer; border: 1px solid #d7dbd0;
    background: #fff; color: #555;
  }
  .modal-actions button.primary {
    background: #2E9F5C; border-color: #2E9F5C; color: #fff;
  }
  .modal-actions button.primary:disabled { opacity: .55; cursor: default; }
  /* toast */
  #toast {
    position: fixed; bottom: 28px; left: 50%; transform: translateX(-50%);
    background: rgba(30,32,28,.88); color: #fff; font-size: 13px;
    border-radius: 20px; padding: 8px 18px; z-index: 60; transition: opacity .3s;
    opacity: 0; pointer-events: none;
  }
  #toast.show { opacity: 1; }
  .stamp { font-size: 11px; color: #b3b8ac; text-align: center; margin-top: 6px; }
</style>
</head>
<body>
<header>
  <div>
    <h1>声物记 · 随手记</h1>
    <div class="sub">电脑访问服务 · 端口 9527</div>
  </div>
  <div class="spacer"></div>
  <div class="conn"><span class="dot" id="connDot"></span><span id="connText">连接中…</span></div>
  <button class="refresh" id="refreshBtn">↻ 刷新</button>
</header>
<main>
  <div id="list"></div>
  <div class="stamp" id="stamp"></div>
</main>

<div id="editMask" hidden>
  <div class="modal">
    <h3>编辑笔记</h3>
    <textarea id="editText"></textarea>
    <div class="modal-actions">
      <button id="editCancel">取消</button>
      <button id="editSave" class="primary">保存</button>
    </div>
  </div>
</div>
<div id="toast"></div>

<script>
'use strict';
const state = { notes: [], editingId: null };
const $ = (id) => document.getElementById(id);

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

function formatTime(iso) {
  if (!iso) return '';
  const d = new Date(iso); // 无时区后缀 → 按本机时区解析（手机写入即本地时间）
  if (isNaN(d)) return iso;
  const p = (n) => String(n).padStart(2, '0');
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) +
    ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

function formatDuration(sec) {
  const n = Number(sec);
  if (!n || n <= 0) return '';
  const m = Math.floor(n / 60), s = Math.round(n % 60);
  return m + ':' + String(s).padStart(2, '0');
}

const TAG_LABEL = { urgent: '⚠ 紧急', star: '★ 收藏', idea: '💡 灵感' };

function renderContent(text) {
  // 清单行 `- [ ]` / `- [x]` 渲染成勾选框（展示用，不可改——清单在手机端语音维护）
  return text.split('\n').map((line) => {
    const m = line.match(/^\s*[-*]\s+\[( |x|X)\]\s+(.*)$/);
    if (m) {
      const done = m[1].toLowerCase() === 'x';
      return '<div class="checkline' + (done ? ' done' : '') + '">' +
        '<input type="checkbox" disabled' + (done ? ' checked' : '') + '>' +
        '<span>' + escapeHtml(m[2]) + '</span></div>';
    }
    return escapeHtml(line);
  }).join('\n');
}

function cardHtml(n) {
  const chips = [];
  const dur = formatDuration(n.duration);
  if (dur) chips.push('<span class="chip">▶ ' + dur + '</span>');
  if (n.tag && TAG_LABEL[n.tag]) chips.push('<span class="chip tag-' + escapeHtml(n.tag) + '">' + TAG_LABEL[n.tag] + '</span>');
  return '<div class="card" data-id="' + n.id + '">' +
    '<div class="meta"><span>' + formatTime(n.createdAt) + '</span>' + chips.join('') + '</div>' +
    '<div class="content">' + renderContent(n.content) + '</div>' +
    (n.hasAudio ? '<audio controls preload="none" src="' + n.audioUrl + '"></audio>' : '') +
    '<div class="actions">' +
      '<button class="copy" data-act="copy" data-id="' + n.id + '">📋 复制</button>' +
      '<button class="edit" data-act="edit" data-id="' + n.id + '">✏️ 编辑</button>' +
      '<button class="danger" data-act="delete" data-id="' + n.id + '">🗑 删除</button>' +
    '</div></div>';
}

function render() {
  const active = state.notes.filter((n) => !n.isArchived);
  const archived = state.notes.filter((n) => n.isArchived);
  let html = '';
  html += '<div class="section-title">日记 <span class="count">' + active.length + '</span></div>';
  html += active.length ? active.map(cardHtml).join('') : '<div class="empty">还没有日记内容<br>在手机上说一句试试</div>';
  if (archived.length) {
    html += '<div class="section-title">已归档 <span class="count">' + archived.length + '</span>（在电脑上删除 = 彻底删除）</div>';
    html += archived.map(cardHtml).join('');
  }
  $('list').innerHTML = html;
}

function updateStamp() {
  const p = (n) => String(n).padStart(2, '0');
  const d = new Date();
  $('stamp').textContent = '最后刷新 ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

async function load(silent) {
  try {
    const r = await fetch('/api/notes', { cache: 'no-store' });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const data = await r.json();
    state.notes = data.notes || [];
    render();
    updateStamp();
    if (!silent) setConn('live');
  } catch (e) {
    setConn('error');
    toast('加载失败：' + e.message);
  }
}

/* ---------- 实时刷新（SSE） ---------- */
function setConn(mode) {
  const dot = $('connDot'), text = $('connText');
  dot.className = 'dot ' + (mode === 'live' ? 'live' : mode === 'reconnecting' ? 'reconnecting' : '');
  text.textContent = mode === 'live' ? '实时同步' : mode === 'reconnecting' ? '重连中…' : '连接断开';
}
function connectSSE() {
  const es = new EventSource('/api/events');
  es.onopen = () => { setConn('live'); load(true); };
  es.onmessage = (e) => {
    if (e.data === 'changed') { load(true); toast('内容已更新'); }
  };
  es.onerror = () => setConn('reconnecting'); // EventSource 自动重连
}

/* ---------- 复制 / 编辑 / 删除 ---------- */
async function copyNote(id) {
  const n = state.notes.find((x) => x.id === id);
  if (!n) return;
  const text = n.content;
  try {
    if (window.isSecureContext && navigator.clipboard) {
      await navigator.clipboard.writeText(text);
    } else {
      // 页面经 http://<手机IP>:9527 访问，非 localhost 的 http 不是安全上下文，
      // navigator.clipboard 为 undefined，只能降级 execCommand；
      // execCommand 依赖用户手势的同步调用栈，故此分支不能经过任何 await
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.focus();
      ta.select();
      const ok = document.execCommand('copy');
      document.body.removeChild(ta);
      if (!ok) throw new Error('浏览器拒绝了复制操作');
    }
    toast('已复制到剪贴板');
  } catch (e) {
    toast('复制失败：' + e.message);
  }
}
function openEdit(id) {
  const n = state.notes.find((x) => x.id === id);
  if (!n) return;
  state.editingId = id;
  $('editText').value = n.content;
  $('editMask').hidden = false;
  $('editText').focus();
}
function closeEdit() {
  $('editMask').hidden = true;
  state.editingId = null;
}
async function saveEdit() {
  const btn = $('editSave');
  btn.disabled = true;
  try {
    const r = await fetch('/api/notes/' + state.editingId, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content: $('editText').value }),
    });
    if (!r.ok) throw new Error(await r.text());
    closeEdit();
    toast('已保存，手机上同步更新');
    load(true);
  } catch (e) {
    toast('保存失败：' + e.message);
  } finally {
    btn.disabled = false;
  }
}
async function deleteNote(id) {
  const n = state.notes.find((x) => x.id === id);
  const preview = n ? n.content.slice(0, 40).replace(/\n/g, ' ') : '';
  if (!confirm('确定删除这条笔记吗？' + (n && n.hasAudio ? '（含录音，不可恢复）' : '（不可恢复）') + '\n\n' + preview)) return;
  try {
    const r = await fetch('/api/notes/' + id, { method: 'DELETE' });
    if (!r.ok) throw new Error(await r.text());
    toast('已删除，手机上同步更新');
    load(true);
  } catch (e) {
    toast('删除失败：' + e.message);
  }
}

/* ---------- toast ---------- */
let toastTimer = null;
function toast(msg) {
  const el = $('toast');
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), 2200);
}

/* ---------- 事件 ---------- */
$('refreshBtn').addEventListener('click', () => load());
$('list').addEventListener('click', (e) => {
  const btn = e.target.closest('button[data-act]');
  if (!btn) return;
  const id = Number(btn.dataset.id);
  if (btn.dataset.act === 'copy') copyNote(id);
  if (btn.dataset.act === 'edit') openEdit(id);
  if (btn.dataset.act === 'delete') deleteNote(id);
});
$('editCancel').addEventListener('click', closeEdit);
$('editSave').addEventListener('click', saveEdit);
$('editMask').addEventListener('click', (e) => { if (e.target === $('editMask')) closeEdit(); });
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !$('editMask').hidden) closeEdit();
});

load();
connectSSE();
</script>
</body>
</html>
''';
