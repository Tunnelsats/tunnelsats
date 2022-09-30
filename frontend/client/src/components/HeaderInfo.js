import React from "react";
import { Alert, Row, Col } from "react-bootstrap";
import { SiTorproject } from "react-icons/si";
import { TbSum } from "react-icons/tb";
import { IoGitNetworkSharp } from "react-icons/io5";
import { FaNetworkWired } from "react-icons/fa";

const HeaderInfo = (props) => {
  return (
    <div>
      <Alert variant="secondary">
        {/* <Alert.Heading>How it works:</Alert.Heading> */}
        <p>
          Tunnel⚡️Sats provides scripts for lightning nodes enabling hybrid
          mode (Clearnet & Tor) and offers paid VPN servers on various
          continents for fixed terms. Our secured and LN-only configured VPNs
          support port-forwarding to connect with other lightning nodes.
          <br></br>
          <br></br>
          <b>How Tunnel⚡️Sats works</b>
          <br></br>Select a preferred region, timeframe and pay the invoice via
          lightning to receive a WireGuard configuration file. Please follow the
          detailed installation instructions described on the TunnelSats{" "}
          <a
            href="https://blckbx.github.io/tunnelsats/"
            target="_blank"
            rel="noreferrer"
          >
            guide
          </a>{" "}
          and{" "}
          <a
            href="https://blckbx.github.io/tunnelsats/FAQ.html"
            target="_blank"
            rel="noreferrer"
          >
            faq
          </a>{" "}
          pages.
        </p>
        <hr />
        Lightning Node Statistics
        <Row>
          <Col>
            <TbSum size={20} title="sum" />
            <br />
            {props.stats[0]}
          </Col>
          <Col>
            <FaNetworkWired size={20} title="clearnet" />
            <br />
            {props.stats[1]}
          </Col>
          <Col>
            <IoGitNetworkSharp size={20} title="hybrid" />
            <br />
            {props.stats[2]}
          </Col>
          <Col>
            <SiTorproject size={20} title="Tor" />
            <br />
            {props.stats[3]}
          </Col>
        </Row>
        {/*
        <p className="mb-0">
          WireGuard keys are generated exclusively within the browser!
        </p>
        */}
      </Alert>
    </div>
  );
};

export default HeaderInfo;
