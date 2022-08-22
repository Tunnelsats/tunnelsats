import React from 'react'
import {ToggleButtonGroup,ToggleButton} from 'react-bootstrap'
const RuntimeSelector = (props) => {
  return (
    <div>
    <ToggleButtonGroup type="radio" name="options" id="runtimeselector" defaultValue={0.001} >
      <ToggleButton id="tbg-radio-1" variant="secondary" value={0.001} onClick={props.onClick}>
        1 <br></br> month
      </ToggleButton>
      <ToggleButton id="tbg-radio-2" variant="secondary" value={0.002} onClick={props.onClick}>
        3 <br></br> months
      </ToggleButton>
      <ToggleButton id="tbg-radio-3" variant="secondary" value={0.003} onClick={props.onClick}>
        6 <br></br> months
      </ToggleButton>
      <ToggleButton id="tbg-radio-4" variant="secondary" value={0.004} onClick={props.onClick}>
        12 <br></br> months
      </ToggleButton>
    </ToggleButtonGroup>
    </div>
  )
}

export default RuntimeSelector
