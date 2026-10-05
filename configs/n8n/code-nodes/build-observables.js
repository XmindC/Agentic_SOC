// n8n Code node "Code in JavaScript" (exported from the live workflow)
// Observables from the normalized alert: Suricata (src_ip/dest_ip) or host (srcip/dstip). Nulls skipped.
const n = $('Normalize').first().json;
const caseId = $('HTTP Request').first().json._id;

return [[n.source_ip, 'Source address'], [n.dest_ip, 'Target address']]
  .filter(([data]) => data)
  .map(([data, message]) => ({ json: { caseId, dataType: 'ip', data, message } }));
