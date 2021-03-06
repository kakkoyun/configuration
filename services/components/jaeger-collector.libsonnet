// These are the defaults for this components configuration.
// When calling the function to generate the component's manifest,
// you can pass an object structured like the default to overwrite default values.
local defaults = {
  local defaults = self,
  name: 'jaeger-collector',
  namespace: error 'must set namespace for jaeger',
  version: error 'must provide version',
  image: error 'must set image for jaeger',
  replicas: error 'must provide replicas',
  pvc: {
    class: 'standard',
    size: '50Gi',
  },
  ports: {
    admin: 14269,
    query: 16686,
    grpc: 14250,
    metrics: 14271,
  },
  resources: {},
  serviceMonitor: false,

  commonLabels:: {
    'app.kubernetes.io/name': 'jaeger-collector',
    'app.kubernetes.io/instance': defaults.name,
    'app.kubernetes.io/version': defaults.version,
    'app.kubernetes.io/component': 'tracing',
  },

  podLabelSelector:: {
    [labelName]: defaults.commonLabels[labelName]
    for labelName in std.objectFields(defaults.commonLabels)
    if labelName != 'app.kubernetes.io/version'
  },
};

function(params) {
  local j = self,

  // Combine the defaults and the passed params to make the component's config.
  config:: defaults + params,
  // Safety checks for combined config of defaults and params
  assert std.isNumber(j.config.replicas) && j.config.replicas >= 0 : 'jaeger replicas has to be number >= 0',
  assert std.isObject(j.config.resources),
  assert std.isBoolean(j.config.serviceMonitor),

  headlessService: {
    apiVersion: 'v1',
    kind: 'Service',
    metadata: {
      name: 'jaeger-collector-headless',
      namespace: j.namespace,
      labels: { 'app.kubernetes.io/name': j.deployment.metadata.name },
    },
    spec: {
      ports: [
        { name: 'grpc', targetPort: j.config.ports.grpc, port: j.config.ports.grpc },
      ],
      selector: j.deployment.metadata.labels,
      clusterIP: 'None',
    },
  },

  queryService: {
    apiVersion: 'v1',
    kind: 'Service',
    metadata: {
      name: 'jaeger-query',
      namespace: j.namespace,
      labels: { 'app.kubernetes.io/name': j.deployment.metadata.name },
    },
    spec: {
      ports: [
        { name: 'query', targetPort: j.config.ports.query, port: j.config.ports.query },
      ],
      selector: j.deployment.metadata.labels,
    },
  },

  adminService: {
    apiVersion: 'v1',
    kind: 'Service',
    metadata: {
      name: 'jaeger-admin',
      namespace: j.namespace,
      labels: { 'app.kubernetes.io/name': j.deployment.metadata.name },
    },
    spec: {
      ports: [
        { name: 'admin', targetPort: j.config.ports.admin, port: j.config.ports.admin },
      ],
      selector: j.deployment.metadata.labels,
    },
  },

  agentService: {
    apiVersion: 'v1',
    kind: 'Service',
    metadata: {
      name: 'jaeger-agent-discovery',
      namespace: j.namespace,
      labels: { 'app.kubernetes.io/name': 'jaeger-agent' },
    },
    spec: {
      ports: [
        { name: 'metrics', targetPort: j.config.ports.metrics, port: j.config.ports.metrics },
      ],
      selector: { 'app.kubernetes.io/tracing': 'jaeger-agent' },
    },
  },

  volumeClaim: {
    apiVersion: 'v1',
    kind: 'PersistentVolumeClaim',
    metadata: {
      name: 'jaeger-store-data',
      namespace: j.namespace,
      labels: { 'app.kubernetes.io/name': j.deployment.metadata.name },
    },
    spec: {
      accessModes: ['ReadWriteOnce'],
      storageClassName: j.config.pvc.class,
      resources: {
        requests: {
          storage: j.config.pvc.size,
        },
      },
    },
  },

  deployment:
    local c = {
      name: j.deployment.metadata.name,
      image: j.config.image,
      args: ['--collector.queue-size=4000'],
      env: [{
        name: 'SPAN_STORAGE_TYPE',
        value: 'memory',
      }],
      ports: [
        {
          assert std.isString(name),
          assert std.isNumber(j.config.ports[name]),

          name: name,
          containerPort: j.config.ports[name],
        }
        for name in std.objectFields(j.config.ports)
      ],
      volumeMounts: [
        { name: 'jaeger-store-data', mountPath: '/var/jaeger/store', readOnly: false },
      ],
      livenessProbe: { failureThreshold: 4, periodSeconds: 30, httpGet: {
        scheme: 'HTTP',
        port: j.config.ports.admin,
        path: '/',
      } },
      readinessProbe: { failureThreshold: 3, periodSeconds: 30, initialDelaySeconds: 10, httpGet: {
        scheme: 'HTTP',
        port: j.config.ports.admin,
        path: '/',
      } },
      resources: {
        requests: { cpu: '1', memory: '1Gi' },
        limits: { cpu: '4', memory: '4Gi' },
      },
    };

    {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: {
        name: j.config.name,
        namespace: j.config.namespace,
        labels: j.config.commonLabels,
      },
      spec: {
        replicas: j.config.replicas,
        selector: { matchLabels: j.config.podLabelSelector },
        strategy: {
          rollingUpdate: {
            maxSurge: 0,
            maxUnavailable: 1,
          },
        },
        template: {
          metadata: {
            labels: j.deployment.metadata.labels,
          },
          spec: {
            containers: [c],
            volumes: [{
              name: j.volumeClaim.metadata.name,
              persistentVolumeClaim: {
                claimName: j.volumeClaim.metadata.name,
              },
            }],
          },
        },
      },
    },

  serviceMonitor: if j.config.serviceMonitor == true then {
    apiVersion: 'monitoring.coreos.com/v1',
    kind: 'ServiceMonitor',
    metadata+: {
      name: j.config.name,
      namespace: j.config.namespace,
      labels: j.config.commonLabels,
    },
    spec: {
      selector: { matchLabels: j.config.podLabelSelector },
      endpoints: [
        { port: 'admin' },
      ],
      namespaceSelector: { matchNames: ['${NAMESPACE}'] },
    },
  },
}
