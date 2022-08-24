import React from 'react'
import {ToggleButtonGroup,ToggleButton} from 'react-bootstrap'




// Env Variables to have the same code base main and dev
const REACT_APP_ONE_MONTH = process.env.REACT_APP_ONE_MONTH || 0.001
const REACT_APP_THREE_MONTHS= process.env.REACT_APP_THREE_MONTHS || 0.002
const REACT_APP_SIX_MONTHS = process.env.REACT_APP_SIX_MONTHS || 0.003
const REACT_APP_ONE_YEAR = process.env.REACT_APP_ONE_YEAR || 0.004


const RuntimeSelector = (props) => {
  return (
    <div>
    <ToggleButtonGroup type="radio" name="options" id="runtimeselector" defaultValue={REACT_APP_THREE_MONTHS} >
      <ToggleButton id="tbg-radio-1" variant="secondary" value={REACT_APP_ONE_MONTH} onClick={props.onClick}>
        1 <br></br> month
      </ToggleButton>
      <ToggleButton id="tbg-radio-2" variant="secondary" value={REACT_APP_THREE_MONTHS} onClick={props.onClick}>
        3 <br></br> months
      </ToggleButton>
      <ToggleButton id="tbg-radio-3" variant="secondary" value={REACT_APP_SIX_MONTHS} onClick={props.onClick}>
        6 <br></br> months
      </ToggleButton>
      <ToggleButton id="tbg-radio-4" variant="secondary" value={REACT_APP_ONE_YEAR} onClick={props.onClick}>
        12 <br></br> months
      </ToggleButton>
    </ToggleButtonGroup>
    </div>
  )
}

export default RuntimeSelector
