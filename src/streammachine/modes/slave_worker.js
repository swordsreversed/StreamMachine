require("coffee-script/register")

cluster       = require("cluster")
SlaveWorker   = require("../slave/slave_worker")

process.title = "StreamM:slaveWorker"

worker = new SlaveWorker()