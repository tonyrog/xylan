xylan (aka proXY wedding)
=========================

Proxy wedding service is a service where you can
start a server side in the network and the client
side on a local server and allow users to access
the local servers over internet in a general way.

The server need a server config that routes connection
to the correct local client proxy, there may be more than
one "local" machine.

Example server config:

    {xylan, [
       {mode, server},
       {id, "server"},
       %% Listen ports {interface-name,port} | {interface-ip,port} | port
       {port, [
         46122,                 %% default listen port 
         {"eth0",222},          %% listen port 222 bound to eth0
         {"127.0.0.1", 222}     %% listen port 222 bound to localhost
       },
       {client_port, 29390},    %% port where client connects
       {data_port, 29391},      %% client callback proxy port
       {auth_timeout, 5000},    %% client session auth timeout
       {data_timeout, 5000},    %% user initial data timeout
       {user_socket_options, [{send_timeout, 5000},{send_timeout_close,true}]},
       {client_socket_options, [{send_timeout, 20000},{send_timeout_close,true}]},
       {clients, [
         {"home", [
	   %% Keys may be generated with xylan:generate_key(), 
	   %% if 64 bit big-endian integer is enough. 
	   %% Otherwise any binary/io-list will do.
           {server_key,  3177648541185394227},  %% server is signing using this key
           {client_key,  12187761947737533676}, %% client is signing using this key
	   {user_socket_options, [{sndbuf, 4096}]},
	   {client_socket_options, [{sndbuf, 2048}]},
           {route, [
    	     [{data, "SSH-2.0.*"}],
             [{data, "GET .*"}]
           ]}
         ]},

         {"ssh", [
           {server_key, <<1,2,3,4,5,6,7,8>>},  %% server is signing using this key
           {client_key, "hello"},              %% client is signing using this key
	   {user_socket_options, [{sndbuf, 8192}]},

           {route, [
    	     [{ip,"eth0"},{port,222},{data, "SSH-2.0.*"}],
           ]}
         ]}
       ]}
     ]}

Client routing:  "home"

    %% config
    {xylan,
      [{mode, client},
       {id, "home"},
       {server_ip,  "192.168.1.13"},
       {server_port, 29390},
       {server_key,  3177648541185394227},  %% server is signing using this key
       {client_key,  12187761947737533676}, %% client is signing using this key
       {ping_interval, 20000},              %% keep alive interval
       {pong_timeout,  3000},               %% keep alive timeout
       {reconnect_interval, 5000},          %% reconnect "delay"
       {auth_timeout, 4000},                %% timeout to wait for authentication
       {service_socket_options, [{sndbuf,4096},{rcvbuf,4096}]},
       {server_socket_options, [{sndbuf,8192},{rcvbuf,2048}]},

       {route,[
         { [{data, "SSH-2.0.*"},{port,22}],  [{port,22}] },
         { [{data, "GET .*"}],  [{ip,"127.0.0.1"},{port,8888}] },
         { [{port,23},{src_ip,"216.58.209.132"}],  [{ip,"eth0"},{port,23}] }
       ]}
    ]}.

Options available for determin the route / client

    {data, RE}     Match initial data for match, as a special case
                   if RE is 'ssl' then data is check for a SSL client 
                   connect pattern.

    {dst_ip, RE}   Match destination ip address, that is the server ip address
                   of the xylan server. The RE may also be an IP tuple in 
                   which case the destination IP is matched exactly

    {dst_port, RE} Match destination port number with a regular expression
                   or a port number.

    {src_ip, RE}   Match source ip address, that is the clients ip address
                   The RE may also be an IP tuple in which case the destination
                   IP is matched exactly

    {src_port, RE} Match destination port number with a regular expression
                   or a port number.

Client options for connecting a matching route

    {port,Port}    Port number to connect to. if a list is given as Port number
                   this is interpreted as a unix domain socket.

    {ip, Name}     IP address to connect to, this default to {127,0,0,1}.
                   Only ipv4 is supported right now. Name can also be an 
		   interface name, in which case the interface address
		   (ipv4) is used.

Socket options

Socket options may be set to control buffer size and delay sending,
no_delay etc.

On server side you set options like

    {xylan,
        [{mode,server},
         ...
	 {user_socket_options, [user_side_option()]},
         {client_socket_options, [device_side_option()]},
         ...
         {clients, [
            {"home", [
            {user_socket_options, [user_side_option()]},
            {client_socket_options, [client_side_option()]}
            ...
        ]}

The user_side_option() and client_side_option() may be set to
any of the inet tcp options, with exceptions of packet, mode, active
header, exit_on_close and raw.

On the client side you may set socket options in a similar way

    {xylan,
        [{mode, client},
         ...
         {service_socket_options, [service_side_option()]},
         {server_socket_options, [server_side_option()]},
         ...
    }

The service_socket_options are the options set towards the local
machine on the device while the server_socket_options are the
upstream options towards the central server.

Useful socket options (read inet:setopts for more deatails )

    {sndbuf, Size}
                    Limit or Increase the amount the kernel is buffering for
                    when sending to the socket.
    {rcvbuf, Size}
                    Limit or Increase the amount the kernel is buffering for
                    when reading from the socket.
    {buffer, Size}
                    Driver buffer size.
    {packet_size, Integer}
                    Set maximum valid packet size.
    {send_timemout, Integer}
                    Set the sending timeout on a socket, this has the effect of
                    closing the connection if the othr party does not consume 
                    the data timely.
    {send_timeout_close, Boolean}
                    Make sure the socket closes when the timeout out is 
                    triggered. This may affect how many sockets are available
                    at any given moment.
    {nodelay, Boolean}
                    Tell kernel to send data as soon as possible and that it
                    does not try to buffer anything.
    {delay_send, Boolean}
                    Do not try to send data immediatly but put on a queue
                    in the erlang driver.
    {keepalive, Boolean}
                    Tell kernel to periodic send data to keep it alive.
    {high_msgq_watermark, Size}
                    See inet:setopts for details
    {high_watermark, Size}
                    See inet:setopts for details
    {low_msgq_watermark, Size}
                    See inet:setopts for details
    {low_watermark, Size}
                   See inet:setopts for details
    {show_econnreset,Boolean}
                    Report RST as an error
