module.exports = {
  guide: [
    {
      type: 'category',
      label: 'Getting Started',
      collapsed: false,
      items: [
        {type: 'doc', id: 'index', label: 'Installation'},
        'greeters',
        'configuration',
      ],
    },
    {
      type: 'category',
      label: 'Greeter Development',
      collapsed: false,
      items: [
        'greeter-development/setup',
        'greeter-development/api',
      ],
    },
  ],
};
