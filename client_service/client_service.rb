#!/usr/bin/ruby
require 'sinatra'
require 'opcua/client'
require 'rest-client'

##
# This class is used to hold the active threads that poll information
# from the OPC servers for specific cobots. It uses a class variable
# to be able to access the threads from each call of an endpoint.
class ActiveThreads
  @@threads = {}

  def self.threads
    @@threads
  end
end

##
# This class is used to hold the OPC client connections to the OPC servers
# of the cobots. The use of a class variable enables to use a single
# connection to each cobot across all calls of the service.
class OpcConnection
  @@conns = {}

  def self.connections
    @@conns
  end

  ##
  # Creates and stores a new connection
  # If there is already a connection for the given +cobot_id+ it will be returned
  # Otherwise a new connection will be created and returned
  def self.connect(cobot_id, address)
    @@conns.fetch(cobot_id) do |id|
      @@conns[id] = OPCUA::Client.new(address)
      @@conns[id].subscription_interval = 500 # default 500
      @@conns[id].default_ns = 2
      # @@conns[id].debug = false
      @@conns[id]
    end
  end

  ##
  # Disconnects from the connection specified by +cobot_id+ and removes it from the storage variable.
  def self.disconnect(cobot_id)
    @@conns[cobot_id]&.disconnect
    @@conns.delete(cobot_id)
  end
end

configure do
  set :bind, '0.0.0.0' # needed to be reachable outside of localhost
  set :port, 4567 # specifies the used port
end

##
# Constant of available cobots and their OPC server addresses.
COBOT_OPC_ADDRESSES = { cobot1: 'opc.tcp://192.168.0.210:4840',
                        cobot2: 'opc.tcp://192.168.0.211:4840' }.freeze
##
# Constant of the Bonita Workflow Management System address.
BONITA_URL = 'http://192.168.0.200:8080'.freeze

before do
  # Sets the format of the logger.
  logger.formatter = proc do |severity, datetime, _progname, msg|
    "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}  #{msg}\n"
  end
end

##
# Sets the response content type for all calls under /cobots* to 'application/json'
before('/cobots*') do
  content_type :json
end

helpers do
  ##
  # Opens a terminal on the machine this service is running on,
  # which shows a message and closes itself after the specified duration.
  # It is used for example to simulate a display mounted to a cobot.
  def terminal_message(title, msg, duration_ms)
    logger.info("Created terminal message with title => #{title}, message => #{msg}, duration_ms => #{duration_ms}")
    puts `exec gnome-terminal -- bash -c '#{"echo #{title};" if title}echo #{msg};exec sleep #{duration_ms / 1000.0}'`
  end

  ##
  # Checks if an entry for the given cobot_id exists and creates a connection.
  # If a problem occurs it stops the request and sends back an error message.
  def connect_client(cobot_id)
    address = COBOT_OPC_ADDRESSES.fetch(cobot_id.to_sym) { raise ArgumentError, "No entry for: #{cobot_id}" }
    OpcConnection.connect(cobot_id, address)
  rescue ArgumentError => e
    halt(404, { message: "#{e.message} => To get available cobots use endpoint: GET /cobots" }.to_json)
  rescue RuntimeError => e
    halt(404, { message: e.message }.to_json)
  end

  ##
  # Connects to the specified cobot and the requested node.
  # If the node is not available it reconnects one time
  # (may happen when the cobot of its OPC server went offline in between).
  # If the node is still unavailable and the connection is fine it is likely wrong
  # and an error message is sent back.
  # Returns the OPC client variable and the node variable.
  def connect_node(cobot_id, node_id)
    client = connect_client(cobot_id)
    node = client.get(node_id)
    unless node
      # try reconnecting once
      OpcConnection.disconnect(cobot_id)
      client = connect_client(cobot_id)
      node = client.get(node_id)
      halt(404, { message: "Invalid NodeID: #{node_id}" }.to_json) unless node
    end
    [client, node]
  end

  ##
  # Handles the login process to the REST API of the Bonita Workflow Management System.
  # Returns the cookies created by the request.
  def bonita_login
    username = 'API'
    pwd = 'bpm'
    payload = "username=#{username}&password=#{pwd}"
    resp = RestClient.post("#{BONITA_URL}/bonita/loginservice", payload)
    logger.info('Bonita login')
    logger.info('Response')
    logger.info(resp.code)
    logger.info(resp.headers)
    logger.info(resp.cookies)
    logger.info('Bonita login successful')
    resp.cookies
  rescue RestClient::ExceptionWithResponse => e
    logger.error(e.response)
  end

  ##
  # Handles the logout process from the REST API of the Bonita Workflow Management System.
  def bonita_logout(cookies)
    headers = { cookies: cookies }
    resp = RestClient.get("#{BONITA_URL}/bonita/logoutservice", headers)
    logger.info('Bonita logout')
    logger.info('Response')
    logger.info(resp.code)
    logger.info(resp.headers)
    logger.info('Bonita logout successful')
  rescue RestClient::ExceptionWithResponse => e
    logger.error(e.response)
  end

  ##
  # Sends a message to the Bonita Workflow Management System, where it triggers a specific 'catch message event'.
  def bonita_message_event_callback(cookies, message_name, target_process, process_instance_id, role_id)
    payload = {
      messageName: message_name,
      targetProcess: target_process,
      correlations: {
        processInstanceIdKey: {
          value: process_instance_id,
          type: 'java.lang.Long'
        },
        roleIdKey: {
          value: role_id,
          type: 'java.lang.String'
        }
      }
    }
    headers = {
      content_type: :json,
      'X-Bonita-API-Token': cookies.fetch('X-Bonita-API-Token'),
      cookies: cookies
    }
    logger.info('bonita_message_event_callback:')
    logger.info('payload:')
    logger.info(payload.to_json)
    logger.info('headers')
    logger.info(headers)
    resp = RestClient.post("#{BONITA_URL}/bonita/API/bpm/message", payload.to_json, headers)
    logger.info('Bonita message event callback')
    logger.info('Response')
    logger.info(resp.code)
    logger.info(resp.headers)
    logger.info('Bonita message event callback successful')
  rescue RestClient::ExceptionWithResponse => e
    logger.error(e.response)
  end

  ##
  # Creates a thread that performs a handshake with a cobot and
  # then performs a callback to the Bonita Workflow Management System.
  # The cobot and bit used is specified by +cobot_id+ and +bit_no+.
  # Handshake:
  # Client side: set +bit_no_in=true+ -> wait +bit_no_out=true+ -> set +bit_no_out=false+ -> wait +bit_no_out=false+
  # Cobot side: wait +bit_no_in=true+ -> set +bit_no_out=true+ -> wait +bit_no_in=false+ -> set +bit_no_out=false+
  # Message details are specified by +message_name+, +process_instance_id+ and +target_process+.
  def handshake(cobot_id, bit_no, message_name, process_instance_id, target_process)
    return if ActiveThreads.threads.key?(cobot_id)

    node_id_in = "/#{cobot_id}/Register/Inputs/Bitregister/Bit#{bit_no}"
    node_id_out = "/#{cobot_id}/Register/Outputs/Bitregister/Bit#{bit_no}"
    ActiveThreads.threads[cobot_id] = Thread.new do
      logger.info("Starting thread for handshake on cobot=>#{cobot_id} and bit=>#{bit_no}")
      c, node_in = connect_node(cobot_id, node_id_in)
      node_out = c.get(node_id_out)
      logger.info("#{cobot_id}: Inputs/Bitregister/Bit#{bit_no} => #{node_in.value}")
      logger.info("#{cobot_id}: Outputs/Bitregister/Bit#{bit_no} => #{node_out.value}")
      node_in.value = true
      logger.info("#{cobot_id}: Inputs/Bitregister/Bit#{bit_no} => #{node_in.value}")
      show = 0
      until node_out.value
        show += 1
        if show >= 4
          logger.info("Checking handshake for #{cobot_id} Outputs/Bitregister/Bit#{bit_no}")
          show = 0
        end
        sleep(c.subscription_interval / 1000.0)
      end
      logger.info("#{cobot_id}: Outputs/Bitregister/Bit#{bit_no} => #{node_out.value}")
      node_in.value = false
      logger.info("#{cobot_id}: Inputs/Bitregister/Bit#{bit_no} => #{node_in.value}")
      show = 0
      while node_out.value
        show += 1
        if show >= 4
          logger.info("Checking handshake for #{cobot_id} Outputs/Bitregister/Bit#{bit_no}")
          show = 0
        end
        sleep(c.subscription_interval / 1000.0)
      end
      logger.info("#{cobot_id}: Outputs/Bitregister/Bit#{bit_no} => #{node_out.value}")

      # send message to Bonita message event
      cookies = bonita_login
      logger.info(cookies)
      bonita_message_event_callback(cookies, message_name, target_process, process_instance_id, cobot_id)
      bonita_logout(cookies)
      logger.info("Ending thread for /cobots/#{cobot_id}/handshake/#{bit_no}")
      ActiveThreads.threads.delete(cobot_id)
    end
  end
end

##
# Returns available endpoints offered by the service as json.
get '/' do
  content_type :json
  endpoints = { endpoints: [
    { url: '/cobots', method: 'GET', description: 'Lists available cobots.' },
    { url: '/cobots/threads', method: 'GET', description: 'Lists active threads.' },
    { url: '/cobots/connections', method: 'GET', description: 'Lists active OPC client connections.' },
    { url: '/cobots/:cobot_id/power_on', method: 'POST', description: 'Sends power_on to a cobot.' },
    { url: '/cobots/:cobot_id/power_off', method: 'POST', description: 'Sends power_off to a cobot.' },
    { url: '/cobots/:cobot_id/programs', method: 'GET',
      description: 'Lists available programs of the corresponding cobot.' },
    { url: '/cobots/:cobot_id/programs/:prog_name/select', method: 'POST', description: 'Loads a program.' },
    { url: '/cobots/:cobot_id/programs/start', method: 'POST', description: 'Starts a loaded program.' },
    { url: '/cobots/:cobot_id/programs/pause', method: 'POST', description: 'Pauses a running program.' },
    { url: '/cobots/:cobot_id/programs/stop', method: 'POST', description: 'Stops a running program.' },
    { url: '/cobots/:cobot_id/handshake/:bit_no', method: 'POST', description: 'Starts a handshake process.' },
    { url: '/cobots/:cobot_id/node/:node_id', method: 'GET',
      description: 'Returns the value of the corresponding node.' },
    { url: '/cobots/:cobot_id/node/:node_id', method: 'PUT', description: 'Sets the value of the corresponding node.' },
    { url: '/cobots/:cobot_id/position/:pos_id', method: 'PUT', description: 'Sends a position to a cobot.' },
    { url: '/linaxis/:axis_id/move/:direction', method: 'POST',
      description: 'Simulates a linear axis moving in a certain direction.' },
    { url: '/partdetectionsystem/scan', method: 'GET', description: 'Simulates scanning of parts.' },
    { url: '/partdetectionsystem/process', method: 'GET', description: 'Simulates processing of an image.' },
    { url: '/callback/:role_id', method: 'POST',
      description: 'Creates a callback thread that sends a message to Bonita after a certain duration.' },
    { url: '/inspectionsystem/scan', method: 'GET', description: 'Simulates a scanning process.' },
    { url: '/random/boolean', method: 'GET', description: 'Returns a random boolean with a certain probability.' },
    { url: '/random/integer', method: 'GET', description: 'Returns a random integer within a certain range.' },
    { url: '/notification', method: 'POST',
      description: 'Creates a notification by opening a terminal showing a message.' }
  ] }
  endpoints.to_json
end

##
# Returns available cobots as json.
get '/cobots' do
  cobots = { cobots: COBOT_OPC_ADDRESSES.map do |name, address|
    { name: name.to_s, address: address, url: "/cobots/#{name}" }
  end }
  cobots.to_json
end

##
# Returns a list of active threads as json.
get '/cobots/threads' do
  ActiveThreads.threads.to_json
end

##
# Returns a list of active OPC client connections as json.
get '/cobots/connections' do
  OpcConnection.connections.to_json
end

##
# Sends a power on signal to the cobot (+cobot_id+).
post '/cobots/:cobot_id/power_on' do |cobot_id|
  node_id = "/#{cobot_id}/PowerOn"
  _client, node = connect_node(cobot_id, node_id)
  node.call
  { message: "Sent PowerOn to #{cobot_id}" }.to_json
end

##
# Sends a power off signal to the cobot (+cobot_id+).
# Additionally, closes the OPC connection to the cobot.
post '/cobots/:cobot_id/power_off' do |cobot_id|
  node_id = "/#{cobot_id}/PowerOff"
  _client, node = connect_node(cobot_id, node_id)
  node.call
  OpcConnection.disconnect(cobot_id)
  { message: "Sent PowerOff to #{cobot_id}" }.to_json
end

##
# Returns available programs of the cobot (+cobot_id+) as json.
get '/cobots/:cobot_id/programs' do |cobot_id|
  node_id = "/#{cobot_id}/Programs/Programs"
  _client, node = connect_node(cobot_id, node_id)
  message = node.value ? node.value.map { |program_name| { name: program_name } } : []
  message.to_json
end

##
# Loads the program of cobot (+cobot_id+).
post '/cobots/:cobot_id/programs/*/select' do |cobot_id, prog_name|
  node_id = "/#{cobot_id}/SelectProgram"
  _client, node = connect_node(cobot_id, node_id)
  prog_name.slice!('.urp')
  node.call("/#{prog_name}")
  { message: "Selected Program #{prog_name} for #{cobot_id}" }.to_json
end

##
# Starts the currently loaded program of cobot (+cobot_id+).
# Optionally, the program is started with a callback only if
# the additional parameters +messageName+, +processInstanceId+,
# +targetProcess+ and +handshakeBitNo+ are sent in the request body as json.
post '/cobots/:cobot_id/programs/start' do |cobot_id|
  message_name, process_instance_id, target_process, bit_no = nil
  req_body = request.body.read
  unless req_body.empty?
    json_params = JSON.parse(req_body, { symbolize_names: true })
    message_name = json_params[:messageName]
    process_instance_id = json_params[:processInstanceId]
    target_process = json_params[:targetProcess]
    bit_no = json_params[:handshakeBitNo]
  end
  node_id = "/#{cobot_id}/StartProgram"
  _client, node = connect_node(cobot_id, node_id)
  node.call

  if message_name && process_instance_id && target_process && bit_no
    ret_message = "Started program for #{cobot_id} with callback"
    logger.info('Starting program with callback')
    logger.info("Params: messageName => #{message_name}, processInstanceId => #{process_instance_id}, "\
    "targetProcess => #{target_process}, bit_no => #{bit_no}")
    handshake(cobot_id, bit_no, message_name, process_instance_id, target_process)
  else
    ret_message = "Started program for #{cobot_id} without callback"
    logger.info('Starting program without callback')
  end
  { message: ret_message }.to_json
rescue JSON::ParserError => e
  logger.error(e.message)
  halt(400, { message: 'Requires JSON: messageName->String, processInstanceId->Long, targetProcess->String '\
    'handshakeBitNo->Integer(64..127) or none at all' }.to_json)
end

##
# Pauses the program of cobot (+cobot_id+).
post '/cobots/:cobot_id/programs/pause' do |cobot_id|
  node_id = "/#{cobot_id}/PauseProgram"
  _client, node = connect_node(cobot_id, node_id)
  node.call
  { message: "Paused program for #{cobot_id}" }.to_json
end

##
# Stops the program of cobot (+cobot_id+) and ends possibly existing threads for this cobot.
post '/cobots/:cobot_id/programs/stop' do |cobot_id|
  node_id = "/#{cobot_id}/StopProgram"
  _client, node = connect_node(cobot_id, node_id)
  node.call
  logger.info("Ending thread for #{cobot_id}")
  ActiveThreads.threads.delete(cobot_id)&.kill
  { message: "Stopped program for #{cobot_id}" }.to_json
end

##
# Starts a handshake process for cobot (+cobot_id+) on bit (+bit_no+)
# with message parameters (+messageName+, +processInstanceId+ and +targetProcess+).
post '/cobots/:cobot_id/handshake/:bit_no' do |cobot_id, bit_no|
  json_params = JSON.parse(request.body.read, { symbolize_names: true })
  message_name = json_params[:messageName]
  process_instance_id = json_params[:processInstanceId]
  target_process = json_params[:targetProcess]
  unless message_name && process_instance_id && target_process
    logger.info('Missing params')
    halt(400, { message: 'Mandatory Parameters: messageName, processInstanceId, targetProcess' }.to_json)
  end
  logger.info("Params: messageName => #{message_name}, processInstanceId => #{process_instance_id}, "\
    "targetProcess => #{target_process}")
  handshake(cobot_id, bit_no, message_name, process_instance_id, target_process)
  { message: "Started callback for /cobots/#{cobot_id}/handshake/#{bit_no}" }.to_json
rescue JSON::ParserError => e
  logger.error(e.message)
  halt(400, { message: 'Requires JSON: messageName->String, processInstanceId->Long, targetProcess->String' }.to_json)
end

##
# Returns the value of the specified node of cobot (+cobot_id+) as json.
get '/cobots/:cobot_id/node/*' do |cobot_id, node_id|
  node_id_temp = "/#{cobot_id}/#{node_id}"
  _client, node = connect_node(cobot_id, node_id_temp)
  message = { node: node_id_temp, value: node.value }
  message.to_json
end

##
# Updates the value of the specified node of cobot (+cobot_id+)
# with the value specified by +value+ in the request body (json formatted).
put '/cobots/:cobot_id/node/*' do |cobot_id, node_id|
  json_params = JSON.parse(request.body.read, { symbolize_names: true })
  val = json_params[:value]
  unless val
    logger.info('Missing param')
    halt(400, { message: 'Mandatory Parameters: value' }.to_json)
  end

  logger.info("Param: value => #{val}")
  node_id_temp = "/#{cobot_id}/#{node_id}"
  _client, node = connect_node(cobot_id, node_id_temp)
  node.value = val
  { message: "Set #{node_id_temp} to #{val}" }.to_json
rescue JSON::ParserError => e
  logger.error(e.message)
  halt(400, { message: 'Requires JSON: value->bool|int|float' }.to_json)
end

##
# Updates a position on cobot (+cobot_id+) by writing the x, y, z, rx, ry, rz values
# to input double register 24-29 or higher offsets by 6 depending on +pos_id+ (0..3).
put '/cobots/:cobot_id/position/:pos_id' do |cobot_id, pos_id|
  json_params = JSON.parse(request.body.read, { symbolize_names: true })
  x = json_params[:x]
  y = json_params[:y]
  z = json_params[:z]
  rx = json_params[:rx] || 0.0
  ry = json_params[:ry] || 0.0
  rz = json_params[:rz] || 0.0
  pos_id_i = pos_id.to_i
  halt(400, { message: 'pos_id has a range of 0..3' }.to_json) if pos_id_i.negative? || pos_id_i > 3
  unless x && y && z
    logger.info('Missing params')
    halt(400, { message: 'Mandatory Parameters: x, y, z' }.to_json)
  end

  logger.info("PUT /cobots/#{cobot_id}/position/#{pos_id}: Params: x => #{x}, y => #{y}, z => #{z}, "\
    "rx => #{rx}, ry => #{ry}, rz => #{rz}")
  { 24 => x, 25 => y, 26 => z, 27 => rx, 28 => ry, 29 => rz }.each do |k, v|
    node_id = "/#{cobot_id}/Register/Inputs/Doubleregister/Double#{k + pos_id_i * 6}"
    _client, node = connect_node(cobot_id, node_id)
    node.value = v
  end
  { message: "Set Pos#{pos_id} to p[#{x}, #{y}, #{z}, #{rx}, #{ry}, #{rz}]" }.to_json
rescue JSON::ParserError => e
  logger.error(e.message)
  halt(400, { message: 'Requires JSON: x->float, y->float, z->float' }.to_json)
end

##
# Simulates a linear axis (+axis_id+) moving in a certain direction (+direction+) by
# opening a terminal message for the duration (+duration_ms+).
# Immediately returns a message that the linaxis is moving.
# After the duration (+duration_ms+) performs a callback to Bonita with the message
# specified in +messageName+, +processInstanceId+ and +targetProcess+.
post '/linaxis/:axis_id/move/:direction' do |axis_id, direction|
  content_type :json
  json_params = JSON.parse(request.body.read, { symbolize_names: true })
  message_name = json_params[:messageName]
  process_instance_id = json_params[:processInstanceId]
  target_process = json_params[:targetProcess]
  duration_ms = json_params[:duration_ms] || 2000
  unless message_name && process_instance_id && target_process
    logger.info('Missing params')
    halt(400, { message: 'Mandatory Parameters: messageName, processInstanceId, targetProcess' }.to_json)
  end
  logger.info("Params: messageName => #{message_name}, processInstanceId => #{process_instance_id}, "\
    "targetProcess => #{target_process}, duration_ms => #{duration_ms}")
  terminal_message('Linaxis moving', "#{axis_id} is moving #{direction}", duration_ms)
  Thread.new do
    logger.info("Starting thread for /linaxis/#{axis_id}/move/#{direction} with duration_ms=#{duration_ms}")
    sleep(duration_ms / 1000.0)
    # send message to Bonita message event
    cookies = bonita_login
    bonita_message_event_callback(cookies, message_name, target_process, process_instance_id, axis_id)
    bonita_logout(cookies)
    logger.info("Ending thread for /linaxis/#{axis_id}/move/#{direction}")
  end
  { message: "Moving linaxis #{axis_id} in direction #{direction}" }.to_json
rescue JSON::ParserError => e
  logger.error(e.message)
  halt(400, { message: 'Requires JSON: messageName->String, processInstanceId->Long, targetProcess->String, '\
    'duration_ms->Integer (optional)' }.to_json)
end

##
# Simulates scanning of parts by showing a terminal message for two seconds.
# Returns a message that parts are scanned after two seconds.
get '/partdetectionsystem/scan' do
  content_type :json
  logger.info('Partdetectionsystem scanning')
  terminal_message('Partdetectionsystem', 'Scanning', 2000)
  sleep(2)
  { message: 'Parts scanned' }.to_json
end

##
# Simulates processing of an image by showing a terminal message for three seconds.
# Returns a message after three seconds with either the found position (random generated) or +posDetected=false+.
get '/partdetectionsystem/process' do
  content_type :json
  terminal_message('Partdetectionsystem', 'Processing image', 3000)
  # position found in 2/3 of requests
  pos_detected = rand(0..2)
  if pos_detected.zero?
    logger.info('Part detection system processed position: no position found')
    message = { message: 'Processed image', posDetected: false }
  else
    # create random position for a box sized 0,4m * 0,5m * 0,1m
    x = rand(0.0..0.4).round(6)
    y = rand(0.0..0.5).round(6)
    z = rand(0.0..0.1).round(6)
    rx = ry = rz = 0.0
    logger.info("Part detection system processed position x=#{x}, y=#{y}, z=#{z}, rx=#{rx}, ry=#{ry}, rz=#{rz}")
    message = { message: 'Processed image', posDetected: true, posX: x, posY: y, posZ: z, posRX: rx, posRY: ry,
                posRZ: rz }
  end
  sleep(3)
  message.to_json
end

##
# Creates a callback thread that sends a message to Bonita after the duration (+duration_ms+)
# with message details specified by +messageName+, +processInstanceId+, +targetProcess+, and +role_id+.
# Immediately returns a message that the callback process has been started.
post '/callback/:role_id' do |role_id|
  content_type :json
  json_params = JSON.parse(request.body.read, { symbolize_names: true })
  message_name = json_params[:messageName]
  process_instance_id = json_params[:processInstanceId]
  target_process = json_params[:targetProcess]
  duration_ms = json_params[:duration_ms] || 2000
  unless message_name && process_instance_id && target_process
    logger.info('Missing params')
    halt(400, { message: 'Mandatory Parameters: messageName, processInstanceId, targetProcess' }.to_json)
  end
  logger.info("Params: messageName => #{message_name}, processInstanceId => #{process_instance_id}, "\
    "targetProcess => #{target_process}, duration_ms => #{duration_ms}")

  Thread.new do
    logger.info("Starting thread for /callback/#{role_id} with duration_ms=#{duration_ms}")
    sleep(duration_ms / 1000.0)
    # send message to Bonita message event
    cookies = bonita_login
    bonita_message_event_callback(cookies, message_name, target_process, process_instance_id, role_id)
    bonita_logout(cookies)
    logger.info("Ending thread for /callback/#{role_id}")
  end
  { message: "Started callback for #{role_id}" }.to_json
rescue JSON::ParserError => e
  logger.error(e.message)
  halt(400, { message: 'Requires JSON: messageName->String, processInstanceId->Long, targetProcess->String, '\
    'duration_ms->Integer (optional)' }.to_json)
end

##
# Simulates a scanning process by showing a terminal message for two seconds.
# Returns a message that the scan is complete after two seconds.
get '/inspectionsystem/scan' do
  content_type :json
  terminal_message('Inspection system', 'Scanning', 2000)
  logger.info('Inspection system scanning')
  sleep(2)
  { message: 'Scanned' }.to_json
end

##
# Returns a random boolean. Probability of returning +true+ is specified by +probability+.
get '/random/boolean' do
  content_type :json
  probability = params['probability'].nil? ? 50 : params['probability'].to_i
  halt(404, { message: 'probability not within [0,100]' }.to_json) if probability.negative? || probability > 100
  random_int = rand(100)
  res = random_int < probability
  logger.info("/random/boolean called with probability=#{probability} produced result=#{res}")
  { message: 'Random boolean', result: res }.to_json
end

##
# Returns a random integer within the range of +min+ and +max+ (both inclusive).
get '/random/integer' do
  content_type :json
  halt(404, { message: 'max required' }.to_json) if params['max'].nil?
  min = params['min'].nil? ? 0 : params['min'].to_i
  max = params['max'].to_i
  halt(404, { message: "min(#{min}) >= max(#{max})" }.to_json) if min >= max
  random_int = rand(min..max)
  logger.info("/random/integer called with min=#{min} and max=#{max} produced result=#{random_int}")
  { message: 'Random integer', result: random_int }.to_json
end

##
# Creates a notification by opening a terminal showing a message specified by +title+ and +message+.
# Terminal closes after the duration (+duration_ms+).
post '/notification' do
  content_type :json
  json_params = JSON.parse(request.body.read, { symbolize_names: true })
  title = json_params[:title]
  message = json_params[:message]
  duration_ms = json_params[:duration_ms] || 5000
  unless message
    logger.info('Missing params')
    halt(400, { message: 'Mandatory Parameter: message' }.to_json)
  end
  logger.info("Params: title => #{title}, message => #{message}, duration_ms => #{duration_ms}")
  terminal_message(title, message, duration_ms)
  { message: 'Notification created' }.to_json
rescue JSON::ParserError => e
  logger.error(e.message)
  halt(400, { message: 'Requires JSON: message->string, title->string (optional), '\
    'duration_ms->integer (optional)' }.to_json)
end
