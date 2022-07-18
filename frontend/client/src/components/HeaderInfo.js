import React from 'react'
import {Alert} from 'react-bootstrap'

const HeaderInfo = () => {
  return (
    <div>
        <Alert variant="primary">
            {/* <Alert.Heading>How it works:</Alert.Heading> */}
              <p>
               Generate a private key, select a country + duration and pay with Lightning.
               <br></br>Instant delivery.
               <br></br>You need the < a href='https://www.wireguard.com/'>Wireguard</a> VPN client.
               <br></br>We also provide an automated <a href='https://github.com/blckbx/vpn_auto_setup/blob/main/vpn_auto_setup.sh'>installation script</a> to install requirements (cgroup, wireguard, nftables), setup VPN connection, configure lnd.conf and split-tunneling Tor.
              </p>
            <hr />
              <p className="mb-0">
                Keys are generated only within the browser!
              </p>
        </Alert>

        {/* <Container>
          <Row id="guide_row">
            <Button variant="primary">How it works?</Button>
          </Row>
        </Container> */}
        </div>
  )
}

export default HeaderInfo
