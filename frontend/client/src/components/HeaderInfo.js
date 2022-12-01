import React from "react";
import { Alert, Row, Col } from "react-bootstrap";
import { SiTorproject } from "react-icons/si";
import { TbSum } from "react-icons/tb";
import { IoGitNetworkSharp } from "react-icons/io5";
import { FaNetworkWired } from "react-icons/fa";
import CountUp from "react-countup";

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
        </p>
        <p>
          <b className="price">How Tunnel⚡️Sats works</b>
          <br></br>Select a preferred region, timeframe and pay the invoice via
          lightning to receive a WireGuard configuration file. Please follow the
          detailed installation instructions described on the TunnelSats{" "}
          <a
            href="https://tunnelsats.github.io/tunnelsats/"
            target="_blank"
            rel="noreferrer"
          >
            guide
          </a>{" "}
          and{" "}
          <a
            href="https://tunnelsats.github.io/tunnelsats/FAQ.html"
            target="_blank"
            rel="noreferrer"
          >
            faq
          </a>{" "}
          pages.
        </p>
        {/*
        <p>
          <b className="warning">
            ⚠️ Server switch required for EU users on de2.tunnelsats.com! ⚠️
            <br></br>If you are connected to this VPN, please switch from
            de2.tunnelsats.com to de3.tunnelsats.com. Here is how to easily get
            there:{" "}
            <a
              href="https://tunnelsats.github.io/tunnelsats/FAQ.html#phasing-out-de2tunnelsatscom---how-to-switch-to-de3tunnelsatscom"
              target="_blank"
              rel="noreferrer"
            >
              migration guide
            </a>
          </b>
        </p>
        */}
        <hr />
        <p className="price">
          <strong>Lightning Node Statistics</strong>
        </p>
        <Row>
          <Col>
            <TbSum size={20} title="total" />
            <br />
            <CountUp end={props.stats[0]} duration={4.0} className="price" />
          </Col>
          <Col>
            <FaNetworkWired size={20} title="clearnet" />
            <br />
            <CountUp end={props.stats[1]} duration={3.0} className="price" />
          </Col>
          <Col>
            <IoGitNetworkSharp size={20} title="hybrid" />
            <br />
            <CountUp end={props.stats[2]} duration={2.5} className="price" />
          </Col>
          <Col>
            <SiTorproject size={20} title="Tor" />
            <br />
            <CountUp end={props.stats[3]} duration={3.5} className="price" />
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
