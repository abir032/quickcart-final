// Pull an app's logs for a time window, and keep them as a build artifact.

pipeline {
  agent { label 'linux' }

  options {
    timestamps()
    timeout(time: 15, unit: 'MINUTES')
  }

  parameters {
    choice(name: 'LOG_GROUP',
           choices: ['/ecs/qc-prod-use1-orders', '/ecs/qc-prod-use1-orders-canary', '/ecs/qc-prod-use1-ops-sql',
                     '/ecs/qc-dev-use1-orders', '/ecs/qc-dev-use1-orders-canary', '/ecs/qc-dev-use1-ops-sql'],
           description: 'Which service')
    string(name: 'START', defaultValue: '', description: 'UTC, for example 2026-09-29 14:00')
    string(name: 'END', defaultValue: '', description: 'UTC. At most 24 hours after START.')
    string(name: 'FILTER', defaultValue: '', description: 'Optional CloudWatch filter pattern, for example ERROR')
  }

  environment {
    AWS_REGION = 'us-east-1'
  }

  stages {
    stage('Extract') {
      steps {
        sh 'scripts/extract-logs.sh'
      }
    }
  }

  post {
    success {
      archiveArtifacts artifacts: 'logs-*.txt'
    }
  }
}
