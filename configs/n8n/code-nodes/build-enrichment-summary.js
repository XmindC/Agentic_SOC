// n8n Code node "Build Enrichment Summary" (exported from the live workflow)
const alert = $('Webhook').first().json.body;
const caseId = $('Code in JavaScript').first().json.caseId;

// Each item is a Cortex waitreport response (Cortex waits up to 1 minute for the job).
// Success  -> taxonomies.  Failure -> the analyzer finished with an error (reported as such).
// Anything else (Waiting/InProgress after the limit, or a request error) -> unavailable. Never "clean".
const findings = [];

for (const item of $input.all()) {
  const j = item.json;
  const addr = j.data || 'unknown';
  const worker = j.workerName || 'analyzer';

  if (j.status === 'Success' && j.report?.summary?.taxonomies) {
    const tax = j.report.summary.taxonomies
      .map(t => `${t.predicate} ${t.value} (${t.level})`)
      .join(', ');
    findings.push(`${worker} on ${addr}: ${tax || 'finished, no taxonomies returned'}`);
  } else if (j.status === 'Failure') {
    findings.push(`${worker} on ${addr}: analyzer finished with an error: ${j.errorMessage || j.report?.errorMessage || 'no message'}`);
  } else {
    findings.push(`${worker} on ${addr}: unavailable (job did not finish within 60s${j.status ? ', last status ' + j.status : ''})`);
  }
}

return [{
  json: {
    caseId,
    alert,
    enrichment: findings.join('\n'),
  }
}];
