module.exports = {
  guide: [
    {type: 'doc', id: 'index', label: 'Overview'},
    {
      type: 'category',
      label: 'Running the daemon',
      collapsed: false,
      items: [
        'daemon/installation',
        'daemon/configuration',
      ],
    },
    {
      type: 'category',
      label: 'Using the library',
      collapsed: false,
      items: [
        'library/greeter',
        'library/daemon',
        'library/previews',
        'library/ipc',
      ],
    },
    'ipc-protocol',
    'ecosystem',
    {
      type: 'link',
      label: 'API reference',
      href: 'pathname:///zgsld/zig/',
    },
  ],
};
