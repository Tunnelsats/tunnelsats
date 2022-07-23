import React from 'react'
import {Alert} from 'react-bootstrap'

const HeaderInfo = () => {
  return (
    <div>
        <Alert variant="secondary">
            {/* <Alert.Heading>How it works:</Alert.Heading> */}
              <p>TunnelSats provides pre-configured setup scripts for lightning nodes enabling hybrid mode (clearnet & Tor connectivity) and offers paid VPN servers in various countries and fixed timeframes. Our VPNs come with automatically enabled forwarding ports that are used to interconnect with other lightning nodes.
               <br></br><b>- STAGING -</b>
               <br></br><b>How Tunnel⚡️Sats works</b>
               <br></br>1) Generate random keys, select a preferred continent, your desired time period and pay with lightning to receive the WireGuard configuration file for your lightning setup.
               <br></br>
               <br></br>2) Download setup script to install required VPN components, configure your node setup for hybrid mode to exclude Tor traffic from VPN usage (redundancy of connectivity).
               <br></br>
               <br></br>For detailed installation instructions please read the TunnelSats <a href="https://blckbx.github.io/tunnelsats/" target="_blank" rel="noreferrer">guide</a> and <a href="https://blckbx.github.io/tunnelsats/FAQ.html" target="_blank" rel="noreferrer">FAQ</a> page.
              </p>
            <hr />
              <p className="mb-0">
                WireGuard keys are generated exclusively within the browser!
              </p>
        </Alert>
     </div>
  )
}

export default HeaderInfo
