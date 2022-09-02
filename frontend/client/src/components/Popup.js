import React from "react";
import { Modal, Button } from "react-bootstrap";

const Popup = (props) => {
  if (!props.show) {
    return null;
  }

  return (
    <div>
      <Modal
        id="faq_modal"
        show={props.show}
        onHide={props.handleClose}
        centered
      >
        <Modal.Header closeButton>
          <Modal.Title>Something went wrong</Modal.Title>
        </Modal.Header>

        <Modal.Body>{props.errorMessage}</Modal.Body>
        <Modal.Footer>
          <Button variant="outline-warning" onClick={props.handleClose}>
            Close
          </Button>
        </Modal.Footer>
      </Modal>
    </div>
  );
};

export default Popup;
