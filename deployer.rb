#!/usr/bin/env ruby
require 'bundler/setup'
require 'dotenv/load'
require_relative 'app/controllers/deployer_controller'

puts "\n################## HI! this is cdk8s deployer! ####################\n".blue

deployer = DeployerController.new

deployer.step_0
deployer.step_1
# deployer.step_2
deployer.step_3
deployer.step_4
deployer.step_5

puts "\nDONE!\n".blue
