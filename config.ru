# frozen_string_literal: true

require "rubygems"
require "bundler"
require "raven"
require "librato-rack"

Bundler.require

require "dotenv/load"

use Raven::Rack
use Librato::Rack

require_relative "./app.rb"
run App
