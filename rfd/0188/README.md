---
authors: Nahum Shalman <nshalman@edgecast.io>
state: draft
discussion: https://github.com/TritonDataCenter/rfd/issues?q=%22RFD+188%22
---

# RFD 188 Manatee CMON Monitoring Integration

## Problem Statement

We currently operate multiple Manatee clusters across different environments
(Triton itself and Manta) but lack unified monitoring through CMON.

The core issues are:
1. **Limited monitoring visibility** - CMON cannot uniformly monitor all Manatee clusters
2. **Inconsistent metrics exposure** - Different or missing metrics endpoints across environments
3. **Operational blind spots** - Difficulty detecting cluster health issues across all deployments
4. **Manual monitoring overhead** - Operators must check each cluster individually

## Current State

### Existing Monitoring Infrastructure

Manatee already has comprehensive cluster monitoring through the `manatee-adm
pg-status` command, which provides:

- Peer status and replication state
- Cluster generation and WAL information
- Primary/sync/async peer identification
- Error and warning conditions
- Frozen state detection
- PostgreSQL connectivity status

### Current Status Server

Manatee includes a status server (`lib/statusServer.js`) that exposes:
- `/ping` - Health check endpoint
- `/` - Basic status information

## Proposed Solution

### Add Prometheus Metrics Endpoint

Extend the existing status server to expose cluster health metrics in Prometheus format.

#### Implementation Approach

1. **Add `/metrics` endpoint** to existing status server
2. **Use existing cluster monitoring data** from `loadClusterDetails` function
4. **Enable CMON scraping** of all Manatee instances

#### Phase 1: Single Metric Implementation

To prove the safety and viability of metrics exposure, Phase 1 will implement
only a single critical metric: `manatee_peer_postgres_up`.

```javascript
// Add to lib/statusServer.js in both images
server.get('/metrics', function handleMetrics(req, res, next) {
    var clusterArgs = {
        shard: config.shardPath,
        zk: config.zk.connectString,
        skipPostgres: false
    };
    
    loadClusterDetails(clusterArgs, function (err, details) {
        if (err) {
            res.send(500, 'Error loading cluster details');
            return next();
        }
        
        var metrics = formatPostgresUpMetric(details, config);
        res.setHeader('Content-Type', 'text/plain; version=0.0.4; charset=utf-8');
        res.send(200, metrics);
        return next();
    });
});
```

### Phase 1: Single Metric Format

Phase 1 will expose only the PostgreSQL connectivity metric to validate the approach:

```prometheus
# HELP manatee_peer_postgres_up PostgreSQL connectivity (1=up, 0=down)
# TYPE manatee_peer_postgres_up gauge
manatee_peer_postgres_up{shard="shard1.example.com",peer="primary",role="primary"} 1
manatee_peer_postgres_up{shard="shard2.example.com",peer="sync",role="sync"} 1
manatee_peer_postgres_up{shard="shard3.example.com",peer="async",role="async"} 1
```

### CMON Integration

Configure CMON to scrape all Manatee instances using service discovery:

### Phase 1: Single Alert Rule

## Implementation Plan

### Phase 1: Single Metric Proof of Concept

#### Step 1: Development
1. **Create minimal prometheus formatter** (`lib/prometheusFormatter.js`)
2. **Add `/metrics` endpoint** to statusServer.js in both images
3. **Implement `manatee_peer_postgres_up` metric only**
4. **Unit testing** with various PostgreSQL connectivity states

#### Step 2: Testing
1. **Deploy to development** environments
2. **Configure CMON scraping** for test clusters
3. **Validate single metric collection** and format compliance
4. **Test alert rule** with synthetic PostgreSQL failures

#### Step 3: Limited Production Trial
1. **Deploy to staging** with monitoring validation
2. **Enable on select production clusters** for observation
3. **Monitor for performance impact** and stability
4. **Gather operational feedback** on metric utility

### Phase 2: Full Metrics Implementation (Future)

After Phase 1 proves the safety and value of metrics exposure:

#### Additional Metrics (Phase 2)

TODO: This needs to be solidified before implementation.
Ideally based on feedback on what information actually provides
useful signals

```prometheus
# Cluster-level metrics
manatee_cluster_peers_total{shard="..."} 3
manatee_cluster_generation{shard="..."} 42
manatee_cluster_frozen{shard="..."} 0
manatee_cluster_errors_total{shard="..."} 0

# Additional peer-level metrics
manatee_peer_replication_lag_seconds{shard="...",peer="...",role="..."} 0.1
manatee_peer_replication_state{shard="...",peer="...",role="..."} 1
```

#### Phase 2 Implementation
1. **Expand metrics endpoint** with full metric set
2. **Add comprehensive alerting rules**
3. **Create CMON dashboards** for cluster overview
4. **Full production rollout** across all environments
5. **Operational documentation** and runbooks

## Performance Considerations

### Impact Analysis
- **Minimal overhead**: Uses existing `loadClusterDetails` function
- **Small response size**: ~1-2KB for typical 3-node cluster
- **Efficient caching**: 10-second TTL to reduce ZooKeeper load
- **Recommended scrape interval**: 30-60 seconds

## Success Criteria

### Phase 1 Success Criteria
- [ ] Both sdc-manatee and manta-manatee expose `/metrics` endpoint with `manatee_peer_postgres_up` metric
- [ ] CMON successfully scrapes the single metric from test clusters
- [ ] No performance degradation observed on Manatee clusters
- [ ] Operational teams validate metric accuracy against actual PostgreSQL state
- [ ] Metrics endpoint handles error conditions gracefully

### Phase 2 Success Criteria (Future)
- [ ] Full metrics suite implemented across all environments
- [ ] Comprehensive alerting rules operational
- [ ] Operational teams confirm improved monitoring capabilities

## Risk Assessment

### Low Risk
- **Minimal code changes**: Adding endpoint to existing status server
- **Proven data source**: Uses existing cluster monitoring functions
- **Gradual rollout**: Can be enabled progressively

### Mitigation Strategies
- **Stop Scraping**: If we don't scrape, the code will not be run.
- **Comprehensive testing**: Full validation in development/staging
- **Rollback plan**: Can revert to previous image versions if issues arise

## References

- [Manatee CLI status implementation](https://github.com/TritonDataCenter/manatee/blob/master/lib/adm.js#L577-L582)
- [Prometheus Metrics Format](https://prometheus.io/docs/instrumenting/exposition_formats/)
- [CMON Documentation](https://github.com/TritonDataCenter/triton-cmon)
- [Existing Manatee Status Server](https://github.com/TritonDataCenter/manatee/blob/master/lib/statusServer.js)
