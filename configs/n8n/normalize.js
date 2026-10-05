// n8n Code node "Normalize" (mode: Run Once for All Items).
// Sits between Webhook and the existing Filter/enrichment chain.
// Suricata alerts carry data.src_ip / data.dest_ip; host alerts (sshd, syscheck,
// Kali, Mac) carry data.srcip / data.dstip. This flattens both into one shape.
// `raw` keeps the original alert, so old references to $json.body.X become $json.raw.X.
const out=[];
for (const item of $input.all()){
  const a=item.json.body||item.json, d=a.data||{}, ag=a.agent||{}, r=a.rule||{}, sc=a.syscheck||{};
  out.push({json:{
    agent_name:ag.name||'unknown', source_ip:d.src_ip||d.srcip||null,
    dest_ip:d.dest_ip||d.dstip||null, user:d.dstuser||d.srcuser||null,
    file:sc.path||null, rule_id:r.id||null, rule_level:r.level||0,
    rule_desc:r.description||'', rule_groups:r.groups||[],
    signature:(d.alert&&d.alert.signature)||r.description||'Wazuh alert',
    timestamp:a.timestamp||null, raw:a }});
}
return out;
