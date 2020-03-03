# frozen_string_literal: true

require 'rubygems'
require 'bundler'

Bundler.require

require 'dotenv/load'

require_relative './app.rb'
run App
