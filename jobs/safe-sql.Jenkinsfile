// Run ONE SQL statement safely. Dry-run shows the effect and rolls back.
// Commit needs someone to approve it.

pipeline {
  agent { label 'linux' }

  options {
    timestamps()
    timeout(time: 30, unit: 'MINUTES')
    disableConcurrentBuilds()
  }

  parameters {
    choice(name: 'ENVIRONMENT', choices: ['dev', 'prod'], description: 'Which database. Commits to either need an approval.')
    text(name: 'SQL', defaultValue: '', description: 'One statement. No semicolons inside it.')
    choice(name: 'MODE', choices: ['dry-run', 'commit'], description: 'dry-run runs it and then rolls it back, so you can see the effect safely')
    string(name: 'TICKET', defaultValue: '', description: 'Ticket number or reason. Required.')
    booleanParam(name: 'ALLOW_DDL', defaultValue: false, description: 'Allow CREATE and ALTER. These commit immediately and cannot be dry-run.')
  }

  environment {
    AWS_REGION       = 'us-east-1'
    TF_IN_AUTOMATION = '1'
    TF_INPUT         = '0'
  }

  stages {
    stage('Approve a commit') {
      when { expression { params.MODE == 'commit' } }
      steps {
        timeout(time: 15, unit: 'MINUTES') {
          input message: "Commit this SQL to ${params.ENVIRONMENT}? Ticket ${params.TICKET}:\n\n${params.SQL}",
                ok: 'Commit it'
        }
      }
    }

    stage('Run the SQL') {
      steps {
        sh 'ENV_DIR="infra/envs/$ENVIRONMENT/us-east-1" scripts/safe-sql.sh'
      }
    }
  }
}
