// QuickCart delivery pipeline.
//
// Pull request: test, build, check the Terraform, post the dev plan on the PR.
// Merge to main: push the image, deploy dev, smoke test, then — after approval —
// a 10% canary in production, judged against docs/canary-criteria.md, then promote.

@Library('quickcart-lib') _

pipeline {
  agent { label 'linux' }

  options {
    timestamps()
    timeout(time: 90, unit: 'MINUTES')
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  environment {
    AWS_REGION       = 'us-east-1'
    GH_REPO          = 'abir032/quickcart-final'
    TF_IN_AUTOMATION = '1'
    TF_INPUT         = '0'
    DEV_DIR          = 'infra/envs/dev/us-east-1'
    PROD_DIR         = 'infra/envs/prod/us-east-1'
  }

  stages {
    stage('Prepare') {
      steps {
        script {
          env.ACCOUNT_ID = sh(returnStdout: true, script: 'aws sts get-caller-identity --query Account --output text').trim()
          env.REGISTRY   = "${env.ACCOUNT_ID}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"
          env.IMAGE      = "${env.REGISTRY}/quickcart/orders"
          env.IMAGE_TAG  = sh(returnStdout: true, script: 'git rev-parse --short=7 HEAD').trim()
          env.TOPIC_ARN  = "arn:aws:sns:${env.AWS_REGION}:${env.ACCOUNT_ID}:quickcart-pipeline"
        }
        echo "Commit ${env.IMAGE_TAG} on ${env.BRANCH_NAME}"
      }
    }

    stage('Test the app') {
      steps {
        dir('app') {
          sh '''
            python3 -m venv .venv
            . .venv/bin/activate
            pip install -q -r requirements-dev.txt
            flake8 --max-line-length 100 app.py test_app.py
            mkdir -p ../reports
            pytest -q --junitxml=../reports/pytest.xml
          '''
        }
      }
      post {
        always { junit 'reports/pytest.xml' }
      }
    }

    stage('Build the image') {
      steps {
        sh 'docker build --build-arg APP_VERSION="$IMAGE_TAG" -t "$IMAGE:$IMAGE_TAG" app'
      }
    }

    stage('Check the Terraform') {
      steps {
        sh 'scripts/tf-checks.sh'
      }
    }

    stage('Plan dev, post it on the pull request') {
      when { changeRequest() }
      steps {
        withCredentials([usernamePassword(credentialsId: 'github-token',
                                          usernameVariable: 'GH_USER',
                                          passwordVariable: 'GITHUB_TOKEN')]) {
          sh 'scripts/plan-comment.sh "$DEV_DIR"'
        }
      }
      post {
        always { archiveArtifacts artifacts: 'plan.txt', allowEmptyArchive: true }
      }
    }

    stage('Push the image') {
      when { branch 'main' }
      steps {
        // A push can fail on a network blip. Retrying is safe because the
        // step checks first: an immutable tag can only ever be pushed once.
        retry(3) {
          sh '''
            aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
            if aws ecr describe-images --repository-name quickcart/orders --image-ids imageTag="$IMAGE_TAG" >/dev/null 2>&1; then
              echo "$IMAGE:$IMAGE_TAG is already in ECR. Nothing to push."
            else
              docker push "$IMAGE:$IMAGE_TAG"
            fi
          '''
        }
      }
    }

    stage('Deploy to dev') {
      when { branch 'main' }
      steps {
        sh '''
          terraform -chdir="$DEV_DIR" init -input=false >/dev/null
          previous=$(terraform -chdir="$DEV_DIR" output -raw stable_image_tag)
          scripts/release.sh "$DEV_DIR" --stable "$IMAGE_TAG" --canary "$IMAGE_TAG" --weight 0
          aws ssm put-parameter --name /quickcart/dev/previous_stable --value "$previous" --type String --overwrite >/dev/null
        '''
      }
    }

    stage('Smoke test dev') {
      when { branch 'main' }
      steps {
        script {
          def url = sh(returnStdout: true, script: 'terraform -chdir="$DEV_DIR" output -raw alb_url').trim()
          smokeTest(url: url, version: env.IMAGE_TAG)
        }
      }
    }

    stage('Approve a production canary') {
      when { branch 'main' }
      steps {
        sh '''
          scripts/release.sh "$PROD_DIR" --canary "$IMAGE_TAG" --weight 10 --plan-file canary.tfplan
          terraform -chdir="$PROD_DIR" show -no-color canary.tfplan > prod-canary-plan.txt
        '''
        archiveArtifacts artifacts: 'prod-canary-plan.txt'
        timeout(time: 30, unit: 'MINUTES') {
          input message: "Start a 10% canary of ${env.IMAGE_TAG} in production? Read prod-canary-plan.txt in this build's artifacts first.",
                ok: 'Start the canary'
        }
      }
    }

    stage('Canary in production') {
      when { branch 'main' }
      steps {
        // Apply exactly the plan that was approved — not a fresh one.
        sh 'terraform -chdir="$PROD_DIR" apply -input=false canary.tfplan'
        script {
          def url = sh(returnStdout: true, script: 'terraform -chdir="$PROD_DIR" output -raw alb_url').trim()
          try {
            sh "scripts/canary-check.sh '${url}' '${env.IMAGE_TAG}' 5 1"
          } catch (err) {
            sh 'scripts/release.sh "$PROD_DIR" --weight 0'
            error("Canary aborted: ${env.IMAGE_TAG} broke the criteria. Production is back on its previous version.")
          }
        }
      }
    }

    stage('Promote in production') {
      when { branch 'main' }
      steps {
        sh '''
          previous=$(terraform -chdir="$PROD_DIR" output -raw stable_image_tag)
          scripts/release.sh "$PROD_DIR" --stable "$IMAGE_TAG" --canary "$IMAGE_TAG" --weight 0
          aws ssm put-parameter --name /quickcart/prod/previous_stable --value "$previous" --type String --overwrite >/dev/null
        '''
        script {
          def url = sh(returnStdout: true, script: 'terraform -chdir="$PROD_DIR" output -raw alb_url').trim()
          smokeTest(url: url, version: env.IMAGE_TAG)
        }
      }
    }
  }

  post {
    success {
      sh 'aws sns publish --topic-arn "$TOPIC_ARN" --subject "QuickCart $BRANCH_NAME #$BUILD_NUMBER passed" --message "Commit $IMAGE_TAG. $BUILD_URL" >/dev/null || true'
    }
    failure {
      sh 'aws sns publish --topic-arn "$TOPIC_ARN" --subject "QuickCart $BRANCH_NAME #$BUILD_NUMBER FAILED" --message "Commit $IMAGE_TAG. Open the build: $BUILD_URL" >/dev/null || true'
    }
  }
}
