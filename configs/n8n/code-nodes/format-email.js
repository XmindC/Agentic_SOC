// n8n Code node "Format Email" (exported from the live workflow)
// Format Email: turn the L1 markdown note into HTML + a plain-text fallback. Notification only.
const pv = $('Parse Verdict').first().json;
const nz = $('Normalize').first().json;
const caseUrl = `http://<SERVICES_IP>:9000/cases/${$('HTTP Request').first().json._id}/details`;
const FIRST = 'L1 agent escalation (notification only; nothing has been actioned).';

const esc = s => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const inline = s => esc(s)
  .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
  .replace(/(^|\s)_([^_]+?)_(?=\s|$|[.,;:])/g, '$1<em>$2</em>');

function mdToHtml(md) {
  const out = []; let list = false;
  for (const line of String(md || '').split('\n')) {
    const li = line.match(/^\s*-\s+(.*)$/);
    if (li) { if (!list) { out.push('<ul>'); list = true; } out.push(`<li>${inline(li[1])}</li>`); continue; }
    if (list) { out.push('</ul>'); list = false; }
    const h = line.match(/^(#{1,6})\s+(.*)$/);
    if (h) { const n = Math.min(h[1].length + 1, 6); out.push(`<h${n}>${inline(h[2])}</h${n}>`); }
    else if (line.trim()) out.push(`<p>${inline(line)}</p>`);
  }
  if (list) out.push('</ul>');
  return out.join('\n');
}
const mdToText = md => String(md || '').replace(/^#{1,6}\s+/gm, '').replace(/\*\*(.+?)\*\*/g, '$1').replace(/(^|\s)_([^_]+?)_(?=\s|$|[.,;:])/g, '$1$2');

const facts = [
  ['Agent', nz.agent_name],
  ['Rule', `${nz.rule_id} (level ${nz.rule_level}) - ${nz.rule_desc}`],
  ['Source', nz.source_ip || 'n/a'],
  ['Destination', nz.dest_ip || 'n/a'],
];

const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.45;color:#1a1a1a;max-width:720px">
<p><strong>${esc(FIRST)}</strong></p>
<table style="border-collapse:collapse;margin:8px 0">
${facts.map(([k, v]) => `<tr><td style="padding:2px 12px 2px 0;color:#555">${esc(k)}</td><td style="padding:2px 0">${esc(v)}</td></tr>`).join('\n')}
</table>
<hr style="border:none;border-top:1px solid #ddd">
${mdToHtml(pv.noteBody)}
<hr style="border:none;border-top:1px solid #ddd">
<p>Case: <a href="${esc(caseUrl)}">${esc(caseUrl)}</a></p>
<p style="color:#555">Status New, unassigned. A human decides every next step.</p>
</div>`;

const text = [
  FIRST, '',
  ...facts.map(([k, v]) => `${k}: ${v}`), '',
  mdToText(pv.noteBody), '',
  `Case: ${caseUrl}`,
  'Status New, unassigned. A human decides every next step.',
].join('\n');

return [{ json: { html, text } }];
