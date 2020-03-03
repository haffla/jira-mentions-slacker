# frozen_string_literal: true

require "rubygems"
require "bundler"
require "raven"

Bundler.require

require "dotenv/load"

use Raven::Rack

require_relative "./app.rb"
run App
