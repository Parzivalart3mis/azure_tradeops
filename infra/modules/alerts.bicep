// Production alerts. Log alerts query workspace-based Application Insights tables
// (AppRequests, AppMetrics) and Container Apps system logs; the dead-letter alert is a
// native Service Bus metric alert.
import { requiredTags } from '../lib/types.bicep'

param location string
param tags requiredTags
param environmentName string
param workspaceId string
param serviceBusId string
param actionGroupId string

@sys.description('Error-rate threshold in percent over a 5-minute window.')
param errorRateThresholdPct int

@sys.description('p95 latency threshold for order submission, in milliseconds.')
param latencyP95ThresholdMs int

// Prod pages at Sev1; lower environments notify at Sev3 so they never page anyone.
var critical = environmentName == 'prod' ? 1 : 3
var warning = environmentName == 'prod' ? 2 : 3

var logAlerts = [
  {
    name: 'api-error-rate'
    displayName: 'TradeOps API error rate above ${errorRateThresholdPct}%'
    severity: critical
    measure: 'error_rate'
    threshold: errorRateThresholdPct
    query: '''
AppRequests
| where AppRoleName == "tradeops-api" and Name !has "healthz" and Name !has "readyz"
| summarize total = count(), failed = countif(toint(ResultCode) >= 500) by bin(TimeGenerated, 5m)
| where total >= 20
| extend error_rate = 100.0 * failed / total
'''
  }
  {
    name: 'api-latency-p95'
    displayName: 'TradeOps order submission p95 latency above ${latencyP95ThresholdMs} ms'
    severity: warning
    measure: 'p95_ms'
    threshold: latencyP95ThresholdMs
    query: '''
AppRequests
| where AppRoleName == "tradeops-api" and Name startswith "POST /v1/orders"
| summarize p95_ms = percentile(DurationMs, 95), total = count() by bin(TimeGenerated, 5m)
| where total >= 20
'''
  }
  {
    name: 'settlement-failures'
    displayName: 'TradeOps settlements failed after retries'
    severity: critical
    measure: 'failed'
    threshold: 0
    query: '''
AppMetrics
| where Name == "tradeops.transactions.failed"
| summarize failed = sum(Sum) by bin(TimeGenerated, 5m)
'''
  }
  {
    name: 'container-crash-loop'
    displayName: 'TradeOps container restarts or failing probes'
    severity: warning
    measure: 'events'
    threshold: 3
    query: '''
ContainerAppSystemLogs
| where ContainerAppName startswith "ca-tradeops"
| where Reason in ("BackOff", "ContainerCrashing", "ProbeFailed", "ContainerTerminated")
| summarize events = count() by bin(TimeGenerated, 5m), ContainerAppName
'''
  }
]

resource scheduledQueries 'Microsoft.Insights/scheduledQueryRules@2026-03-01' = [
  for alert in logAlerts: {
    name: 'alert-tradeops-${environmentName}-${alert.name}'
    location: location
    tags: tags
    properties: {
      displayName: alert.displayName
      severity: alert.severity
      enabled: true
      scopes: [workspaceId]
      evaluationFrequency: 'PT5M'
      windowSize: 'PT5M'
      autoMitigate: true
      // Tables such as ContainerAppSystemLogs only exist after the first logs arrive.
      skipQueryValidation: true
      criteria: {
        allOf: [
          {
            query: alert.query
            timeAggregation: 'Maximum'
            metricMeasureColumn: alert.measure
            operator: 'GreaterThan'
            threshold: alert.threshold
            failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
          }
        ]
      }
      actions: { actionGroups: [actionGroupId] }
    }
  }
]

resource deadLetters 'Microsoft.Insights/metricAlerts@2026-01-01' = {
  name: 'alert-tradeops-${environmentName}-dead-letters'
  location: 'global'
  tags: tags
  properties: {
    description: 'Messages are landing in the settlement dead-letter queue'
    severity: critical
    enabled: true
    scopes: [serviceBusId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'DeadletteredMessages'
          metricName: 'DeadletteredMessages'
          metricNamespace: 'Microsoft.ServiceBus/namespaces'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Maximum'
          dimensions: [
            { name: 'EntityName', operator: 'Include', values: ['*'] }
          ]
        }
      ]
    }
    actions: [{ actionGroupId: actionGroupId }]
  }
}
