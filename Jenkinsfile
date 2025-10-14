pipeline {

  agent any



  environment {

    AWS_REGION = "us-east-1"

  }



  stages {

    stage('Checkout') {

      steps {

        git branch: 'main', url: 'https://github.com/nigelhenn/aws-terraform-lab.git'

      }

    }



    stage('Terraform Init') {

      steps {

        sh 'terraform init'

      }

    }



    stage('Terraform Plan') {

      steps {

        sh 'terraform plan -out=tfplan'

      }

    }



    stage('Terraform Apply') {

      when {

        branch 'main'

      }

      steps {

        sh 'terraform apply -auto-approve tfplan'

      }

    }

  }

}

