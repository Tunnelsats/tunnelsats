import React from 'react'
import {ToggleButtonGroup,ToggleButton} from 'react-bootstrap'
const RuntimeSelector = (props) => {
  return (
    <div>
    <ToggleButtonGroup type="radio" name="options" id="runtimeselector" defaultValue={3} >
      <ToggleButton id="tbg-radio-1" value={3} onClick={props.onClick}>
        1 <br></br> month
      </ToggleButton>
      <ToggleButton id="tbg-radio-2" value={8.5} onClick={props.onClick}>
        3 <br></br> months
      </ToggleButton>
      <ToggleButton id="tbg-radio-3" value={16} onClick={props.onClick}>
        6 <br></br> months
      </ToggleButton>
      <ToggleButton id="tbg-radio-4" variant="secondary" value={28.5} /*onClick={props.onClick}*/ disabled>
        12 <br></br> months
      </ToggleButton>
    </ToggleButtonGroup>
    </div>
  )
}

export default RuntimeSelector
