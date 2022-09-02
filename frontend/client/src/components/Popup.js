import React from "react";

const Popup = (props) => {
  return (
    <div className="popup-box">
      <Modal onHide={props.handleClose} centered>
        <Modal.Header closeButton>
          <Modal.Title>Something went wrong</Modal.Title>
          <div className="box">{props.errorMessage}</div>
        </Modal.Header>
      </Modal>
    </div>
  );
};

export default Popup;
