#!/usr/bin/env ruby
require 'bundler/setup'
require 'dotenv/load'
require_relative 'app/controllers/deployer_controller'

puts "\n################## HI! this is cdk8s deployer! ####################\n".blue

deployer = DeployerController.new
deployer.run

puts "\nDONE!\n".blue
