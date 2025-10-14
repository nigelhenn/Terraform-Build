pipeline {

  agent any



  environment {

    AWS_REGION = "us-east-1"

  }
}


  stages {

    stage('Checkout') {
    steps {
        git credentialsId: 'github-token', url: 'https://github.com/nigelhenn/aws-terraform-lab.git', branch: 'main'
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

