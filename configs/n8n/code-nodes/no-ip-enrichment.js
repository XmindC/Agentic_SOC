// n8n Code node "No-IP Enrichment" (exported from the live workflow)
// Host alerts with no IP (file integrity, local auth...) skip Cortex but still get L1 triage.
// Same output shape as 'Build Enrichment Summary'.
return [{ json: {
  caseId: $('HTTP Request').first().json._id,
  alert: $('Normalize').first().json.raw,
  enrichment: 'No IP observables on this alert; no reputation lookup performed.',
} }];
