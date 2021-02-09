
function show_error(error) {
  var div = document.getElementById("error")
  div.innerText = error
  div.style.color = 'red'
  div.style.visibility = ''
  setTimeout(() => { div.style.visiblity = 'hidden' }, 2000)
}

function add(due, text) {
  console.log("add", due, text)
  fetch('/add', {
    method: 'POST',
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({due: due, text: text})
  })
  .then(response => refresh())
  .catch((error) => {
    show_error(error)
  })
}

function set_status(id, value) {
  let url = value ? '/done' : '/undone';
  fetch(url, {
    method: 'POST',
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({id: id})
  })
  .catch((error) => {
    show_error(error)
  })
}

function render(item) {
  var li = document.createElement('li')
  var checkbox = document.createElement('input')
  checkbox.setAttribute('type', 'checkbox')
  checkbox.checked = item.pending != "1"
  checkbox.setAttribute('data-id', item.id)
  checkbox.addEventListener('change', (event) => {
    set_status(event.target.getAttribute('data-id'), event.target.checked)
  })
  li.appendChild(checkbox)
  li.appendChild(document.createTextNode(item.due + " " + item.text))
  return li
}

function refresh() {
  let pending_only = document.getElementById('pending').checked
  let url = pending_only ? '/pending' : '/all'
  fetch(url)
    .then((response) => response.json())
    .then((data) => {
      var todo = document.getElementById('todo')
      todo.innerHTML = ""
      for(item of data) {
        todo.appendChild(render(item))
      }
    })
    .catch((error) => {
      document.getElementById("error").innerText = error
    })
}

