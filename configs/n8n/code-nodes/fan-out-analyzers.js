// n8n Code node "Fan out analyzers" (exported from the live workflow)
// One Cortex job per (observable, analyzer). Downstream waitreport + Build Enrichment Summary
// already handle many results, so the L1 agent still runs once per alert.
const analyzers = ["89b6a8415bce4a0557a2bf15bb5436cd::AbuseIPDB_2_0", "0e2a20abae837977fed18ad2359401cd::VirusTotal_GetReport_3_1"];
return $input.all().flatMap(i => analyzers.map(a => ({ json: { ...i.json, analyzer: a } })));
