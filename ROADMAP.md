## StreamMachine Roadmap

### 0.3: Tenacity

Theme: Always recover.

* Add retries to areas that can currently fail to initialize based on state.
* If a slave starts via handoff but doesn't get an open, bound socket, add retry
    logic to reopen the port. 
* Don't get stuck in the state of opening the W3C log file.  Set a timeout on 
    the open and retry if it doesn't happen. 
* Put stronger logic around what happens with an aborted handoff.  Who dies?
    
### 0.4: Preroll

Theme: Bring the preroller in-house to limit dependencies and allow more efficient 
playback.

* Add preroll upload support to master
* Add interface for associating prerolls with stream playlists
* Figure out an efficient method for distributing preroll data to the slaves    

### 0.5: Dashboards

Theme: Internal visibility.

* Add cube as a dependency of the master
* Integrate stream listening dashboard into the master UI
* Add stats endpoints off of the master API

