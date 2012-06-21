#!/usr/bin/node
/*
########################################################
## ZooKeeper Configuration Agent
##
## Connects to a ZooKeeper server, announces the sysinfo 
## data, then waits for configuration parameters to be 
## written. 
## When written, executes the configuration steps and
## terminates.
#######################################################
*/

var cp = require('child_process')
var execString = cp.exec

var fs = require('fs')
var os = require('os')
var ZooKeeper = require("zookeeper")

if(process.argv.length != 4) {
  console.log("Must be executed:");
  console.log("  node "+__filename+" <zookeeper> <usb-root>")
  process.exit(1)
}

// presume we're invoked with node
//  node /some/script.js zoo1.local:2181,zoo2.local:2181
var zookeeperAddress = process.argv[2]
var zookeeperBase = "/hypervisors/unconfigured"

// local provisioning steps
var zpoolScript = "/smartdc/bin/freeagent-configure-zpool.sh";
var configurationPath = process.argv[3] + "/config"

// Connect to ZooKeeper
var zk = null;
var configurationStarted = false;

function sysinfo(callback) {
  execString('/usr/bin/sysinfo', function (error, stdout, stderr) {
    var obj;
    if (error) {
      callback(new Error(stderr.toString()));
    } else {
      stdout_string = stdout.toString();
      obj = JSON.parse(stdout_string);
      callback(null, obj, stdout_string);
    }
  });
}

var provision = function(configuration) {
  console.log("Provisioning:");
  console.log("  executing: "+zpoolScript+" "+configuration["zpool_args"])

  updateZookeeperStatus("Creating zpool");
  execString(zpoolScript + " " + configuration["zpool_args"], function(error, stdout, stderr) {
    console.log("stdout: "+stdout.toString())
    console.log("stderr: "+stderr.toString())

    if (error) {
      console.log("Failed to create zpool: "+stderr.toString());
      zk.close(function() { process.exit(1) });
    } else {
      console.log("zpool created.")
      updateZookeeperStatus("Writing configuration");
      fs.writeFile(configurationPath, configuration['config_file'], function(err) {
        if(err) {
          console.log("Failed to write file: " + err);
          zk.close(function() { process.exit(1) });

        } else {
          console.log("Configuration written. We're done!");
          zk.close(function() { process.exit(0) });
        }
      });
    }
  });
};

// handle the initial connection to zookeeper
var zookeeperConnectReturned = function(err) {
  if( err ) {
    // Bah, we failed to connect.
    console.log("Failed to connect to zookeeper: "+err.toString());

    // Try again in a moment...
    //setTimeout(connectToZookeeper, 2000);
  } else {
    zookeeperConnected();
  }
}
var connectToZookeeper = function() {
  console.log("Connecting to ZooKeeper server at '" + zookeeperAddress + "'");

  zk = new ZooKeeper({
      connect: zookeeperAddress
    , timeout: 2000
    , debug_level: ZooKeeper.ZOO_LOG_LEVEL_WARNING
    , host_order_deterministic: false
  });

  zk.connect(zookeeperConnectReturned);
}
var updateZookeeperStatus = function(msg) {

};

// this is called whenever we notice a new value for the znode we create.
var handleConfigurationData = function(data) {
  console.log("ZooKeeper data retrieved");

  // parse the JSON struct
  try {
    data = JSON.parse(data);
  } catch(e) {
    console.log("Failed to parse JSON: "+e.toString());
    return;
  }

  // do we have a configuration set yet?
  if('provisioning_configuration' in data) {
    if(configurationStarted == true) {
      console.log("Configuration already underway...");
      return;
    }
    configurationStarted = true;
    provision(data['provisioning_configuration']);
  } else {
    console.log("No provisioning config set...");
  }
}

// Zookeeper events
var zookeeperConnected = function() {

  console.log("We're connected!");

  zk.mkdirp(zookeeperBase, function(error) {
    if(error) throw error;

    // grab the sysinfo for this node
    sysinfo(function(error, info, string) {
      var nodeContents = {
        'sysinfo': info
      }

      // write the sysinfo to a node, and keep an eye on it !
      zk.a_create(zookeeperBase + "/smartos-", JSON.stringify(nodeContents), ZooKeeper.ZOO_SEQUENCE | ZooKeeper.ZOO_EPHEMERAL, function(rc, error, config_path) { 
        
        console.log("Node has been created: "+config_path);

        // the initial get
        zk.a_get(config_path, true, function(rc, error, stat, value) { handleConfigurationData(value); });
        
        // keep watching a node!
        zk.on(ZooKeeper.on_event_changed, function( zkk, path ) {

          // keep watching
          zk.a_get(config_path, true, function(rc, error, stat, value) { handleConfigurationData(value); });
        }); //zk.on(ZooKeeper..)
      }); //zk.a_create(zookeeperBase)
    }); // sysinfo
  }); //zk.mkdirp
}

// kick it all off!
connectToZookeeper();

