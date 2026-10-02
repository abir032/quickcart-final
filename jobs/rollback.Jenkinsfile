// One-click rollback. Default: go back to the version before the last release.

@Library('quickcart-lib') _

pipeline {
  agent { label 'linux' }

  options {
    timestamps()
    timeout(time: 30, unit: 'MINUTES')
    disableConcurrentBuilds()
  }

  parameters {
    choice(name: 'ENVIRONMENT', choices: ['prod', 'dev'], description: 'Which environment to roll back')
    string(name: 'IMAGE_TAG', defaultValue: 'previous', description: '"previous" returns to the version before the last release. Or give a commit tag, like a1b2c3d.')
    string(name: 'REASON', defaultValue: '', description: 'Why. Required: it goes into the notification.')
  }

  environment {
    AWS_REGION       = 'us-east-1'
    TF_IN_AUTOMATION = '1'
    TF_INPUT         = '0'
  }

  stages {
    stage('Check the request') {
      steps {
        script {
          if (!params.REASON?.trim()) {
            error('REASON is required.')
          }
          env.ENV_DIR = "infra/envs/${params.ENVIRONMENT}/us-east-1"
          env.TARGET = params.IMAGE_TAG.trim() == 'previous'
            ? sh(returnStdout: true, script: 'aws ssm get-parameter --name "/quickcart/$ENVIRONMENT/previous_stable" --query Parameter.Value --output text').trim()
            : params.IMAGE_TAG.trim()
          sh 'terraform -chdir="$ENV_DIR" init -input=false >/dev/null'
          env.CURRENT = sh(returnStdout: true, script: 'terraform -chdir="$ENV_DIR" output -raw stable_image_tag').trim()
        }
        // Refuse a version that was never built, before touching anything.
        sh 'aws ecr describe-images --repository-name quickcart/orders --image-ids imageTag="$TARGET" >/dev/null'
        echo "Rolling ${params.ENVIRONMENT} back from ${env.CURRENT} to ${env.TARGET}"
      }
    }

    stage('Roll back') {
      steps {
        sh 'scripts/release.sh "$ENV_DIR" --stable "$TARGET" --canary "$TARGET" --weight 0'
      }
    }

    stage('Smoke test') {
      steps {
        script {
          def url = sh(returnStdout: true, script: 'terraform -chdir="$ENV_DIR" output -raw alb_url').trim()
          smokeTest(url: url, version: env.TARGET)
        }
      }
    }

    stage('Record it') {
      steps {
        // The version we left becomes "previous", so a second click undoes the rollback.
        sh 'aws ssm put-parameter --name "/quickcart/$ENVIRONMENT/previous_stable" --value "$CURRENT" --type String --overwrite >/dev/null'
      }
    }
  }

  post {
    always {
      sh '''
        topic="arn:aws:sns:$AWS_REGION:$(aws sts get-caller-identity --query Account --output text):quickcart-pipeline"
        aws sns publish --topic-arn "$topic" \
          --subject "QuickCart rollback of $ENVIRONMENT" \
          --message "Rolled back from $CURRENT to $TARGET. Reason: $REASON. $BUILD_URL" >/dev/null || true
      '''
    }
  }
}
